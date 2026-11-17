# Test çalıştırması 20261117T184218Z

- Sonuç: **BAŞARILI** — 45 PASS / 2 WARN / 0 FAIL (toplam 47)
- Upstream: `9d0d3720f4ca181d87bef94da826d730acc6d483` (main)
- Uygulama sürümü: `{"version":"1.0.3","build":"0.20.19","source_commit":"unknown"}`
- Host: macOS 27.2.1 / arm64, Docker 29.8.2, Compose 5.5.1

## İmajlar

| Servis | İmaj | Digest |
|---|---|---|
| odysseus | `ghcr.io/odysseus-dev/odysseus:latest` | `sha256:5117c5e07e5976095ce213e601277ff372e0387a67de34c5fd59a3de723e6113` |
| chromadb | `docker.io/chromadb/chroma:1.5.9@sha256:1e0b73a187a28757c572acba508c46f48c9e8b0acaf5c20e6d95cdedce1acdf6` | `sha256:1e0b73a187a28757c572acba508c46f48c9e8b0acaf5c20e6d95cdedce1acdf6` |
| searxng | `docker.io/searxng/searxng:2026.10.24-ef0ec03da@sha256:7c7cbe509429e82755104b2a95f52085a98633c95d53f44e4e905fa3a59f08c8` | `sha256:7c7cbe509429e82755104b2a95f52085a98633c95d53f44e4e905fa3a59f08c8` |
| ntfy | `docker.io/binwiederhier/ntfy:v2.32.0@sha256:59250e1d8be2ee2186c4560322f625faef22ace380331f05b63f8842dbd62602` | `sha256:59250e1d8be2ee2186c4560322f625faef22ace380331f05b63f8842dbd62602` |

## Sonuçlar

| Faz | Test | Durum | Detay |
|---|---|---|---|
| preflight | `docker.daemon` | PASS | server 29.8.2 linux/aarch64 |
| preflight | `compose.v2` | PASS | 5.5.1 |
| preflight | `git.present` | PASS | git version 2.54.0 (Apple Git-157) |
| preflight | `docker.memory` | PASS | 7.7 GiB / 8.3 GB (doküman: min 8GB) |
| preflight | `disk.free` | PASS | 667 GiB boş (doküman: ~20GB) |
| preflight | `port.7011` | PASS | boş |
| preflight | `port.8100` | PASS | boş |
| preflight | `port.8080` | PASS | boş |
| preflight | `port.8091` | PASS | boş |
| install | `upstream.commit` | PASS | main @ 9d0d3720f4ca181d87bef94da826d730acc6d483 |
| install | `compose.snapshot` | PASS | docker-compose.yml upstream ile birebir aynı |
| install | `env.created` | PASS | .env.example -> .env (+ .env.test, PUID=501, parola üretildi) |
| install | `compose.config` | PASS | compose config geçerli |
| install | `images.preexisting` | WARN | host'ta zaten var, kaldırmada korunacak: docker.io/chromadb/chroma:1.5.9 |
| install | `compose.up` | PASS | docker compose up -d (173 sn) |
| install | `compose.warnings` | WARN | upstream compose: The "ODYSSEUS_TTS_CACHE_MAX_BYTES" variable is not set (compose dosyasında varsayılan değer yok) |
| install | `app.ready` | PASS | /api/health healthy (208 sn, up dahil) |
| verify | `svc.all_running` | PASS | running: chromadb ntfy odysseus searxng |
| verify | `svc.searxng_healthy` | PASS | searxng health=healthy |
| verify | `svc.no_restarts` | PASS | restartCount: odysseus=0 chromadb=0 searxng=0 ntfy=0 |
| verify | `net.loopback_only` | PASS | odysseus -> 127.0.0.1:7011 chromadb -> 127.0.0.1:8100 searxng -> 127.0.0.1:8080 ntfy -> 127.0.0.1:8091 |
| verify | `app.health` | PASS | {"status":"healthy","timestamp":"2026-11-17T18:45:49.768541+00:00"} |
| verify | `app.version` | PASS | {"version":"1.0.3","build":"0.20.19","source_commit":"unknown"} |
| verify | `app.login_page` | PASS | GET /login -> 200 |
| verify | `auth.status_anon` | PASS | {"configured":true,"authenticated":false} |
| verify | `auth.login_reject` | PASS | yanlış parola -> HTTP 401 |
| verify | `auth.login_admin` | PASS | {"ok":true,"username":"admin"} |
| verify | `auth.session` | PASS | {"authenticated":true,"username":"admin","is_admin":true} |
| verify | `chroma.heartbeat` | PASS | {"nanosecond heartbeat":1794941150261536132} |
| verify | `ntfy.health` | PASS | {"healthy":true,"role":"active"} |
| verify | `searxng.http` | PASS | GET / -> 200 |
| verify | `searxng.json_search` | PASS | format=json -> HTTP 200 |
| verify | `net.internal` | PASS | chromadb=200 searxng=200 ntfy=200  |
| verify | `sec.run_as_puid` | PASS | PID1 uid=501 (PUID=501) |
| verify | `data.bind_mount` | PASS | upstream/data/auth.json mevcut (bind mount) |
| verify | `data.persistence` | PASS | restart sonrası login OK (auth kalıcı) |
| verify | `logs.tracebacks` | PASS | odysseus loglarında Traceback sayısı: 0 |
| uninstall | `compose.down` | PASS | down -v --remove-orphans --rmi all |
| uninstall | `bind_mounts.removed` | PASS | upstream/data, upstream/logs, upstream/.env silindi |
| verify-clean | `clean.containers` | PASS | 0 container |
| verify-clean | `clean.volumes` | PASS | 0 volume |
| verify-clean | `clean.networks` | PASS | 0 network |
| verify-clean | `clean.images` | PASS | testin çektiği 3 imaj silindi |
| verify-clean | `clean.images_preexisting` | PASS | önceden var olan korundu: docker.io/chromadb/chroma:1.5.9 |
| verify-clean | `clean.ports` | PASS | 7011/8100/8080/8091 serbest |
| verify-clean | `clean.bind_mounts` | PASS | data/ ve logs/ yok |
| total | `run.duration` | PASS | 222 sn |
