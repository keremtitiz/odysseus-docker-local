#!/usr/bin/env bash
# Odysseus Docker kurulum / doğrulama / kaldırma test ortamı.
# Resmi akış: https://odysseusai.dev/install/docker
#
# Kullanım:
#   ./odysseus-test.sh full          # preflight -> install -> verify -> uninstall -> verify-clean + rapor
#   ./odysseus-test.sh preflight     # ön koşullar (docker, compose v2, portlar, disk, RAM)
#   ./odysseus-test.sh install       # clone + .env + docker compose up -d + sağlık bekleme
#   ./odysseus-test.sh verify        # fonksiyonel testler
#   ./odysseus-test.sh status        # docker compose ps
#   ./odysseus-test.sh logs          # odysseus servis logları
#   ./odysseus-test.sh uninstall     # down -v --rmi all + bind-mount verilerini sil
#   ./odysseus-test.sh verify-clean  # iz kalmadığını doğrula
#
# Ortam değişkenleri:
#   UPSTREAM_REPO   (varsayılan https://github.com/odysseus-dev/odysseus.git)
#   UPSTREAM_REF    (varsayılan main — doküman main dalını önerir)
#   KEEP_IMAGES=1   uninstall sırasında imajları silme
#   PURGE=1         uninstall sırasında upstream/ klonunu da sil
#   WAIT_TIMEOUT    sağlık bekleme süresi, sn (varsayılan 420)

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/odysseus-dev/odysseus.git}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
UPSTREAM_DIR="$ROOT/upstream"
COMPOSE_FILE_PATH="$ROOT/docker-compose.yml"
ENV_TEST="$ROOT/.env.test"
PROJECT="odysseus-test"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-420}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="$ROOT/reports/$RUN_ID"
RESULTS="$RUN_DIR/results.tsv"
COOKIE_JAR=""
# Kurulumdan önce host'ta zaten bulunan stack imajları (kaldırmada korunur/beklenir)
PREEXISTING="$ROOT/reports/.preexisting-images"

# Upstream'in ön tanımlı sabit portları (compose dosyasında sabit)
CHROMA_PORT=8100
SEARXNG_PORT=8080
NTFY_PORT=8091

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G= R= Y= B= N=; fi
log()  { printf '%s[%s]%s %s\n' "$B" "$(date +%H:%M:%S)" "$N" "$*"; }
warn() { printf '%sUYARI:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sHATA:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

mkdir -p "$RUN_DIR"
[ -f "$RESULTS" ] || printf 'phase\tid\tstatus\tdetail\n' > "$RESULTS"

# --- sonuç kaydı -------------------------------------------------------------
PHASE="-"
FAILS=0
record() { # record ID PASS|FAIL|WARN "detay"
  local id="$1" st="$2" detail="${3:-}"
  detail="$(printf '%s' "$detail" | tr '\t\n' '  ' | cut -c1-300)"
  printf '%s\t%s\t%s\t%s\n' "$PHASE" "$id" "$st" "$detail" >> "$RESULTS"
  case "$st" in
    PASS) printf '  %s✔%s %-34s %s\n' "$G" "$N" "$id" "$detail" ;;
    WARN) printf '  %s!%s %-34s %s\n' "$Y" "$N" "$id" "$detail" ;;
    *)    printf '  %s✘%s %-34s %s\n' "$R" "$N" "$id" "$detail"; FAILS=$((FAILS+1)) ;;
  esac
}
check() { # check ID "açıklama" komut...
  local id="$1" desc="$2"; shift 2
  local out
  if out="$("$@" 2>&1)"; then record "$id" PASS "${out:-$desc}"; else record "$id" FAIL "${out:-$desc}"; fi
}

# --- compose sarmalayıcı -----------------------------------------------------
# Repodaki docker-compose.yml kullanılır; göreli yollar (./config, ./scripts,
# ./data, build: .) upstream klonuna göre çözülür. .env de oradan okunur.
dc() {
  docker compose -p "$PROJECT" --project-directory "$UPSTREAM_DIR" \
    -f "$COMPOSE_FILE_PATH" "$@"
}

# Sorgu amaçlı çağrılar (ps/port/exec): compose uyarıları test detayına karışmasın
dcq() { dc "$@" 2>/dev/null; }

# Bu compose dosyasının kullandığı imaj referansları (varsayılanlarla çözülmüş)
stack_images() {
  docker compose -p "$PROJECT" --project-directory "$UPSTREAM_DIR" -f "$COMPOSE_FILE_PATH" \
    config --images 2>/dev/null \
  || sed -nE 's/^ *image: *//p' "$COMPOSE_FILE_PATH" \
     | sed -E 's/\$\{ODYSSEUS_IMAGE:-([^}]*)\}/\1/'
}

env_get() { # .env içinden değer oku (son tanım geçerli)
  [ -f "$UPSTREAM_DIR/.env" ] || return 0
  grep -E "^$1=" "$UPSTREAM_DIR/.env" | tail -1 | cut -d= -f2-
}
app_port() { local p; p="$(env_get APP_PORT)"; echo "${p:-7011}"; }
app_url()  { echo "http://127.0.0.1:$(app_port)"; }

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# =============================================================================
cmd_preflight() {
  PHASE=preflight; log "Ön koşullar"
  check docker.daemon   "Docker daemon erişilebilir" \
    docker info --format 'server {{.ServerVersion}} {{.OSType}}/{{.Architecture}}'
  check compose.v2      "Compose V2" docker compose version --short
  check git.present     "git" git --version

  local mem_b mem_gb
  mem_b="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  mem_gb="$(awk -v b="$mem_b" 'BEGIN{printf "%.1f GiB / %.1f GB", b/1073741824, b/1e9}')"
  if [ "$mem_b" -ge 8000000000 ]; then record docker.memory PASS "${mem_gb} (doküman: min 8GB)"
  elif [ "$mem_b" -ge 7500000000 ]; then record docker.memory WARN "${mem_gb} — 8GB sınırında (Docker Desktop VM tahsisi)"
  else record docker.memory FAIL "${mem_gb} < 8GB"; fi

  local free_gb
  free_gb="$(df -Pk "$ROOT" | awk 'NR==2{print int($4/1024/1024)}')"
  if [ "$free_gb" -ge 20 ]; then record disk.free PASS "${free_gb} GiB boş (doküman: ~20GB)"
  else record disk.free FAIL "${free_gb} GiB boş < 20GB"; fi

  local p port_list="$(app_port) $CHROMA_PORT $SEARXNG_PORT $NTFY_PORT"
  for p in $port_list; do
    if dc ps -q 2>/dev/null | grep -q .; then record "port.$p" WARN "stack zaten çalışıyor"; continue; fi
    if port_busy "$p"; then record "port.$p" FAIL "port dolu: $(lsof -nP -iTCP:$p -sTCP:LISTEN | awk 'NR==2{print $1}')"
    else record "port.$p" PASS "boş"; fi
  done
}

# =============================================================================
cmd_install() {
  PHASE=install; log "Kurulum (ref=$UPSTREAM_REF)"
  docker info >/dev/null 2>&1 || die "Docker daemon çalışmıyor (Docker Desktop'ı başlatın)."

  # 1) Clone (doküman: main dalı önerilir)
  if [ -d "$UPSTREAM_DIR/.git" ]; then
    log "upstream mevcut, $UPSTREAM_REF güncelleniyor"
    git -C "$UPSTREAM_DIR" fetch --depth 1 origin "$UPSTREAM_REF" -q
    git -C "$UPSTREAM_DIR" checkout -q -B "$UPSTREAM_REF" FETCH_HEAD
  else
    git clone -q --depth 1 -b "$UPSTREAM_REF" "$UPSTREAM_REPO" "$UPSTREAM_DIR"
  fi
  local sha; sha="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
  record upstream.commit PASS "$UPSTREAM_REF @ $sha"
  echo "$sha" > "$RUN_DIR/upstream-commit.txt"

  # Compose drift kontrolü: repodaki snapshot upstream ile aynı mı?
  if cmp -s "$COMPOSE_FILE_PATH" "$UPSTREAM_DIR/docker-compose.yml"; then
    record compose.snapshot PASS "docker-compose.yml upstream ile birebir aynı"
  else
    diff -u "$COMPOSE_FILE_PATH" "$UPSTREAM_DIR/docker-compose.yml" > "$RUN_DIR/compose-drift.diff" || true
    record compose.snapshot WARN "upstream compose değişmiş; bkz. reports/$RUN_ID/compose-drift.diff"
  fi

  # 2) .env (doküman: cp .env.example .env) + test ayarları
  cp "$UPSTREAM_DIR/.env.example" "$UPSTREAM_DIR/.env"
  {
    printf '\n# ---- odysseus-test.sh ekleri (%s) ----\n' "$RUN_ID"
    grep -vE '^[[:space:]]*(#|$)' "$ENV_TEST"
    # Docker Desktop (macOS) dosya sahipliği için host UID/GID
    printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)"
    local pw="${ODYSSEUS_ADMIN_PASSWORD:-$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | cut -c1-24)}"
    printf 'ODYSSEUS_ADMIN_PASSWORD=%s\n' "$pw"
  } >> "$UPSTREAM_DIR/.env"
  chmod 600 "$UPSTREAM_DIR/.env"
  record env.created PASS ".env.example -> .env (+ .env.test, PUID=$(id -u), parola üretildi)"

  local cw
  if cw="$(dc config -q 2>&1)"; then record compose.config PASS "compose config geçerli"
  else record compose.config FAIL "$cw"; return 1; fi

  # Önceden var olan stack imajlarını not et (aynı digest başka etiketle duruyorsa
  # compose çekmez ve --rmi all onu silmez — bu kullanıcı verisidir, korunmalı).
  local ref pre=""
  : > "$PREEXISTING"
  for ref in $(stack_images); do
    if docker image inspect "$ref" >/dev/null 2>&1; then echo "$ref" >> "$PREEXISTING"; pre="$pre ${ref%%@*}"; fi
  done
  [ -z "$pre" ] && record images.preexisting PASS "stack imajlarının hiçbiri önceden yok" \
                || record images.preexisting WARN "host'ta zaten var, kaldırmada korunacak:$pre"

  # 3) docker compose up -d (doküman adımı). Image pull başarısız olursa
  #    compose yerel build'e düşer.
  log "docker compose up -d — ilk çalıştırmada imaj indirme birkaç dakika sürebilir"
  local t0=$SECONDS
  if dc up -d 2>&1 | tee "$RUN_DIR/compose-up.log" | tail -n 15; then
    record compose.up PASS "docker compose up -d ($((SECONDS-t0)) sn)"
    cw="$(grep -o 'The \\"[A-Z_]*\\" variable is not set' "$RUN_DIR/compose-up.log" | tr -d '\\' | sort -u | tr '\n' ' ')"
    [ -z "$cw" ] || record compose.warnings WARN "upstream compose: ${cw}(compose dosyasında varsayılan değer yok)"
  else
    record compose.up FAIL "bkz. reports/$RUN_ID/compose-up.log"; return 1
  fi

  # 4) Sağlık bekleme
  log "Uygulama sağlığı bekleniyor (en fazla ${WAIT_TIMEOUT} sn)"
  local deadline=$((SECONDS + WAIT_TIMEOUT)) ok=0
  while [ $SECONDS -lt $deadline ]; do
    if curl -fsS -m 5 "$(app_url)/api/health" 2>/dev/null | grep -q '"healthy"'; then ok=1; break; fi
    sleep 5
  done
  if [ $ok = 1 ]; then record app.ready PASS "/api/health healthy ($((SECONDS-t0)) sn, up dahil)"
  else
    dc logs --no-color --tail 200 > "$RUN_DIR/odysseus-timeout.log" 2>&1 || true
    record app.ready FAIL "zaman aşımı; bkz. reports/$RUN_ID/odysseus-timeout.log"; return 1
  fi

  # Kullanılan imajların digest'lerini kaydet
  dc images --format json 2>/dev/null > "$RUN_DIR/images.json" || true
  local svc img id
  for svc in odysseus chromadb searxng ntfy; do
    id="$(dc ps -q "$svc" 2>/dev/null | head -1)"
    [ -n "$id" ] || continue
    img="$(docker inspect -f '{{.Config.Image}}' "$id")"
    printf '%s\t%s\t%s\n' "$svc" "$img" \
      "$(docker image inspect -f '{{join .RepoDigests ","}}' "$(docker inspect -f '{{.Image}}' "$id")" 2>/dev/null)" \
      >> "$RUN_DIR/images.tsv"
  done
}

# =============================================================================
http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }

t_services_running() {
  local want="chromadb ntfy odysseus searxng" got
  got="$(dcq ps --status running --services | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$got" = "$want" ] && echo "running: $got" || { echo "beklenen [$want], olan [$got]"; return 1; }
}
t_searxng_healthy() {
  local h; h="$(docker inspect -f '{{.State.Health.Status}}' "$(dcq ps -q searxng)")"
  echo "searxng health=$h"; [ "$h" = healthy ]
}
t_restart_counts() {
  local s id rc bad=0 out=""
  for s in odysseus chromadb searxng ntfy; do
    id="$(dcq ps -q "$s")"; rc="$(docker inspect -f '{{.RestartCount}}' "$id")"
    out="$out $s=$rc"; [ "$rc" = 0 ] || bad=1
  done
  echo "restartCount:$out"; [ $bad = 0 ]
}
container_port() {
  case "$1" in
    odysseus) echo 7000 ;;
    chromadb) echo 8000 ;;
    searxng)  echo 8080 ;;
    ntfy)     echo 80 ;;
  esac
}
t_ports_loopback() {
  local s lines bad=0
  for s in odysseus chromadb searxng ntfy; do
    lines="$(dcq port "$s" "$(container_port "$s")")"
    echo "$s -> $lines"
    echo "$lines" | grep -qv '^127\.0\.0\.1:' && bad=1
  done
  [ $bad = 0 ]
}
t_health()  { local b; b="$(curl -fsS -m 10 "$(app_url)/api/health")"; echo "$b"; echo "$b" | jq -e '.status=="healthy"' >/dev/null; }
t_version() { local b; b="$(curl -fsS -m 10 "$(app_url)/api/version")"; echo "$b" | jq -c .; echo "$b" > "$RUN_DIR/app-version.json"; echo "$b" | jq -e '.version' >/dev/null; }
t_login_page() { local c; c="$(http_code "$(app_url)/login")"; echo "GET /login -> $c"; [ "$c" = 200 ]; }
t_auth_unauth() {
  local b; b="$(curl -fsS -m 10 "$(app_url)/api/auth/status")"; echo "$b" | jq -c '{configured,authenticated}'
  echo "$b" | jq -e '.configured==true and .authenticated==false' >/dev/null
}
t_login_wrong() {
  local c; c="$(http_code -X POST -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"definitely-wrong-password"}' "$(app_url)/api/auth/login")"
  echo "yanlış parola -> HTTP $c"; [ "$c" = 401 ]
}
t_login_ok() {
  local user pw b
  user="$(env_get ODYSSEUS_ADMIN_USER)"; user="${user:-admin}"; pw="$(env_get ODYSSEUS_ADMIN_PASSWORD)"
  b="$(jq -nc --arg u "$user" --arg p "$pw" '{username:$u,password:$p}' \
      | curl -fsS -m 15 -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d @- "$(app_url)/api/auth/login")"
  echo "$b" | jq -c .; echo "$b" | jq -e '.ok==true' >/dev/null
}
t_auth_session() {
  local b; b="$(curl -fsS -m 10 -b "$COOKIE_JAR" "$(app_url)/api/auth/status")"
  echo "$b" | jq -c '{authenticated,username,is_admin}'
  echo "$b" | jq -e '.authenticated==true and .is_admin==true' >/dev/null
}
t_chroma_host() { local b; b="$(curl -fsS -m 10 "http://127.0.0.1:$CHROMA_PORT/api/v2/heartbeat")"; echo "$b"; echo "$b" | grep -q heartbeat; }
t_ntfy_host()   { local b; b="$(curl -fsS -m 10 "http://127.0.0.1:$NTFY_PORT/v1/health")"; echo "$b"; echo "$b" | jq -e '.healthy==true' >/dev/null; }
t_searxng_host(){ local c; c="$(http_code "http://127.0.0.1:$SEARXNG_PORT/")"; echo "GET / -> $c"; [ "$c" = 200 ]; }
t_searxng_json(){
  local c; c="$(http_code "http://127.0.0.1:$SEARXNG_PORT/search?q=docker&format=json")"
  echo "format=json -> HTTP $c"; [ "$c" = 200 ]
}
t_internal_net() {
  dcq exec -T odysseus python -c '
import urllib.request as u
for n,url in [("chromadb","http://chromadb:8000/api/v2/heartbeat"),("searxng","http://searxng:8080/"),("ntfy","http://ntfy:80/v1/health")]:
    r=u.urlopen(url,timeout=8); print(f"{n}={r.status}", end=" ")
'
}
t_run_as_puid() {
  local u; u="$(dcq exec -T odysseus sh -c 'stat -c %u /proc/1 2>/dev/null || ps -o uid= -p 1')"
  u="$(echo "$u" | tr -d '[:space:]')"; echo "PID1 uid=$u (PUID=$(env_get PUID))"; [ "$u" = "$(env_get PUID)" ]
}
t_data_bind() {
  [ -f "$UPSTREAM_DIR/data/auth.json" ] && echo "upstream/data/auth.json mevcut (bind mount)" \
    || { echo "data/auth.json yok"; ls "$UPSTREAM_DIR/data" 2>&1 | head; return 1; }
}
t_persistence() {
  dc restart odysseus >/dev/null 2>&1
  local deadline=$((SECONDS+180))
  until curl -fsS -m 5 "$(app_url)/api/health" 2>/dev/null | grep -q healthy; do
    [ $SECONDS -lt $deadline ] || { echo "restart sonrası sağlıklı olmadı"; return 1; }; sleep 3
  done
  rm -f "$COOKIE_JAR"; t_login_ok >/dev/null && echo "restart sonrası login OK (auth kalıcı)"
}
t_log_errors() {
  local n; n="$(dcq logs --no-color odysseus | grep -c 'Traceback' || true)"
  echo "odysseus loglarında Traceback sayısı: $n"; [ "$n" = 0 ]
}

cmd_verify() {
  PHASE=verify; log "Doğrulama testleri"
  dc ps -q 2>/dev/null | grep -q . || die "Stack çalışmıyor; önce install."
  COOKIE_JAR="$(mktemp "${TMPDIR:-/tmp}/ody-cookie.XXXXXX")"

  check svc.all_running      "4 servis running"           t_services_running
  check svc.searxng_healthy  "searxng healthcheck"        t_searxng_healthy
  check svc.no_restarts      "crash-loop yok"             t_restart_counts
  check net.loopback_only    "portlar 127.0.0.1'e bağlı"  t_ports_loopback
  check app.health           "GET /api/health"            t_health
  check app.version          "GET /api/version"           t_version
  check app.login_page       "GET /login"                 t_login_page
  check auth.status_anon     "anonim auth status"         t_auth_unauth
  check auth.login_reject    "yanlış parola 401"          t_login_wrong
  check auth.login_admin     "admin login"                t_login_ok
  check auth.session         "oturumlu status admin"      t_auth_session
  check chroma.heartbeat     "ChromaDB :8100"             t_chroma_host
  check ntfy.health          "ntfy :8091"                 t_ntfy_host
  check searxng.http         "SearXNG :8080"              t_searxng_host
  if out="$(t_searxng_json 2>&1)"; then record searxng.json_search PASS "$out"
  else record searxng.json_search WARN "$out (dış ağ/arama motoru erişimine bağlı)"; fi
  check net.internal         "container içi servis erişimi" t_internal_net
  check sec.run_as_puid      "uvicorn PUID ile çalışıyor"  t_run_as_puid
  check data.bind_mount      "./data bind mount"           t_data_bind
  check data.persistence     "restart sonrası kalıcılık"   t_persistence
  if out="$(t_log_errors 2>&1)"; then record logs.tracebacks PASS "$out"
  else record logs.tracebacks WARN "$out"; fi

  dc logs --no-color > "$RUN_DIR/compose-logs.txt" 2>&1 || true
  dc ps > "$RUN_DIR/compose-ps.txt" 2>&1 || true
  rm -f "$COOKIE_JAR"
}

# =============================================================================
cmd_uninstall() {
  PHASE=uninstall; log "Kaldırma"
  local rmi=(--rmi all); [ "${KEEP_IMAGES:-0}" = 1 ] && rmi=()
  if [ -d "$UPSTREAM_DIR" ]; then
    # Doküman: down -v named volume'ları (chromadb-data, searxng-data, ntfy-cache) siler.
    if dc down -v --remove-orphans ${rmi[@]+"${rmi[@]}"} 2>&1 | tee "$RUN_DIR/compose-down.log" | tail -n 20; then
      record compose.down PASS "down -v --remove-orphans ${rmi[*]:-}"
    else record compose.down FAIL "bkz. reports/$RUN_ID/compose-down.log"; fi
    # down -v ./data ve ./logs bind mount'larını SİLMEZ (doküman notu) — elle temizle.
    # macOS Docker Desktop'ta dosyalar host kullanıcısına aittir; Linux'ta farklı
    # UID kaldıysa root yetkili tek kullanımlık container ile silinir.
    local d
    for d in data logs; do
      [ -e "$UPSTREAM_DIR/$d" ] || continue
      rm -rf "$UPSTREAM_DIR/$d" 2>/dev/null || \
        docker run --rm -v "$UPSTREAM_DIR:/w" alpine:3.20 rm -rf "/w/$d"
    done
    rm -f "$UPSTREAM_DIR/.env"
    record bind_mounts.removed PASS "upstream/data, upstream/logs, upstream/.env silindi"
  else
    record compose.down WARN "upstream/ yok, atlanıyor"
  fi
  if [ "${PURGE:-0}" = 1 ]; then rm -rf "$UPSTREAM_DIR"; record upstream.purged PASS "upstream/ silindi"; fi
}

cmd_verify_clean() {
  PHASE=verify-clean; log "Kaldırma doğrulaması"
  local lbl="label=com.docker.compose.project=$PROJECT" n
  n="$(docker ps -aq --filter "$lbl" | wc -l | tr -d ' ')"
  [ "$n" = 0 ] && record clean.containers PASS "0 container" || record clean.containers FAIL "$n container kaldı"
  n="$(docker volume ls -q --filter "$lbl" | wc -l | tr -d ' ')"
  [ "$n" = 0 ] && record clean.volumes PASS "0 volume" || record clean.volumes FAIL "$(docker volume ls -q --filter "$lbl" | tr '\n' ' ')"
  n="$(docker network ls -q --filter "$lbl" | wc -l | tr -d ' ')"
  [ "$n" = 0 ] && record clean.networks PASS "0 network" || record clean.networks FAIL "$n network kaldı"
  if [ "${KEEP_IMAGES:-0}" != 1 ]; then
    local ref left="" kept="" removed=0
    for ref in $(stack_images); do
      if [ -f "$PREEXISTING" ] && grep -qxF "$ref" "$PREEXISTING"; then
        docker image inspect "$ref" >/dev/null 2>&1 && kept="$kept ${ref%%@*}"
      elif docker image inspect "$ref" >/dev/null 2>&1; then left="$left ${ref%%@*}"
      else removed=$((removed+1)); fi
    done
    [ -z "$left" ] && record clean.images PASS "testin çektiği $removed imaj silindi" \
                   || record clean.images FAIL "kalan:$left"
    [ -z "$kept" ] || record clean.images_preexisting PASS "önceden var olan korundu:$kept"
  fi
  local p busy=""
  for p in 7011 $CHROMA_PORT $SEARXNG_PORT $NTFY_PORT; do port_busy "$p" && busy="$busy $p"; done
  [ -z "$busy" ] && record clean.ports PASS "7011/8100/8080/8091 serbest" || record clean.ports FAIL "dolu:$busy"
  { [ ! -e "$UPSTREAM_DIR/data" ] && [ ! -e "$UPSTREAM_DIR/logs" ]; } \
    && record clean.bind_mounts PASS "data/ ve logs/ yok" || record clean.bind_mounts FAIL "data/ veya logs/ kaldı"
}

# =============================================================================
write_summary() {
  local pass fail warn total
  pass="$(awk -F'\t' 'NR>1&&$3=="PASS"' "$RESULTS" | wc -l | tr -d ' ')"
  fail="$(awk -F'\t' 'NR>1&&$3=="FAIL"' "$RESULTS" | wc -l | tr -d ' ')"
  warn="$(awk -F'\t' 'NR>1&&$3=="WARN"' "$RESULTS" | wc -l | tr -d ' ')"
  total=$((pass+fail+warn))
  {
    echo "# Test çalıştırması $RUN_ID"
    echo
    echo "- Sonuç: **$([ "$fail" = 0 ] && echo BAŞARILI || echo BAŞARISIZ)** — $pass PASS / $warn WARN / $fail FAIL (toplam $total)"
    echo "- Upstream: \`$(cat "$RUN_DIR/upstream-commit.txt" 2>/dev/null || echo '?')\` ($UPSTREAM_REF)"
    [ -f "$RUN_DIR/app-version.json" ] && echo "- Uygulama sürümü: \`$(jq -c . "$RUN_DIR/app-version.json")\`"
    echo "- Host: $(sw_vers -productName 2>/dev/null || uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r) / $(uname -m), Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null), Compose $(docker compose version --short 2>/dev/null)"
    echo
    if [ -f "$RUN_DIR/images.tsv" ]; then
      echo "## İmajlar"; echo; echo "| Servis | İmaj | Digest |"; echo "|---|---|---|"
      awk -F'\t' '{d=$3; sub(/.*@/,"",d); printf "| %s | `%s` | `%s` |\n",$1,$2,d}' "$RUN_DIR/images.tsv"; echo
    fi
    echo "## Sonuçlar"; echo; echo "| Faz | Test | Durum | Detay |"; echo "|---|---|---|---|"
    awk -F'\t' 'NR>1{gsub(/\|/,"\\|",$4); printf "| %s | `%s` | %s | %s |\n",$1,$2,$3,$4}' "$RESULTS"
  } > "$RUN_DIR/SUMMARY.md"
  cp "$RUN_DIR/SUMMARY.md" "$ROOT/reports/LATEST.md"
  log "Özet: reports/$RUN_ID/SUMMARY.md (kopya: reports/LATEST.md) — $pass PASS / $warn WARN / $fail FAIL"
  [ "$fail" = 0 ]
}

cmd_full() {
  local t0=$SECONDS rc=0
  cmd_preflight
  if [ $FAILS -gt 0 ]; then warn "Ön koşul hatası; kurulum yapılmıyor."; write_summary; return 1; fi
  cmd_install || rc=1
  [ $rc = 0 ] && cmd_verify
  cmd_uninstall
  cmd_verify_clean
  PHASE=total; record run.duration PASS "$((SECONDS-t0)) sn"
  write_summary
}

case "${1:-}" in
  preflight)    cmd_preflight; write_summary ;;
  install)      cmd_install ;;
  verify)       cmd_verify; write_summary ;;
  status)       dc ps ;;
  logs)         dc logs --no-color --tail "${2:-200}" odysseus ;;
  uninstall)    cmd_uninstall ;;
  verify-clean) cmd_verify_clean; write_summary ;;
  full)         cmd_full ;;
  *) sed -n '2,22p' "$0"; exit 2 ;;
esac
