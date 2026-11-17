# Odysseus — Docker kurulum/kaldırma test ortamı

[Odysseus](https://github.com/odysseus-dev/odysseus) için resmi Docker kurulumunu
([odysseusai.dev/install/docker](https://odysseusai.dev/install/docker)) uçtan uca
**kurup, doğrulayıp, iz bırakmadan kaldıran** tekrarlanabilir bir test ortamı.

## İçerik

| Dosya | Açıklama |
|---|---|
| `docker-compose.yml` | Test edilen compose dosyası. Upstream `main` ile **birebir aynı** snapshot; her çalıştırmada upstream ile karşılaştırılır (drift varsa uyarı + diff). |
| `.env.test` | `.env.example` üzerine eklenen test ayarları (proje adı, port, auth). Gizli bilgi içermez. |
| `odysseus-test.sh` | Test betiği: `preflight`, `install`, `verify`, `uninstall`, `verify-clean`, `full`. |
| `reports/LATEST.md` | Son çalıştırmanın özet raporu. |
| `TEST_REPORT.md` | Doğrulanmış test çalıştırmasının raporu ve bulgular. |

## Gereksinimler

- Docker Desktop veya Docker Engine + Compose V2
- `git`, `curl`, `jq`, `openssl`
- Docker'a en az 8 GB RAM, ~20 GB boş disk (doküman gereksinimi)
- Boş portlar: `7011` (UI), `8100` (ChromaDB), `8080` (SearXNG), `8091` (ntfy) — hepsi yalnızca `127.0.0.1`'e bağlanır

## Kullanım

```bash
./odysseus-test.sh full          # tam döngü + rapor (önerilen)

# veya adım adım
./odysseus-test.sh preflight
./odysseus-test.sh install       # stack ayakta kalır → http://127.0.0.1:7011
./odysseus-test.sh verify
./odysseus-test.sh uninstall
./odysseus-test.sh verify-clean
```

| Değişken | Varsayılan | Etki |
|---|---|---|
| `UPSTREAM_REF` | `main` | Test edilecek dal/etiket (`dev` en yeni ama kararsız olabilir) |
| `KEEP_IMAGES=1` | — | Kaldırırken imajları silme (tekrar çalıştırmalar hızlanır) |
| `PURGE=1` | — | Kaldırırken `upstream/` klonunu da sil |
| `WAIT_TIMEOUT` | `420` | Uygulamanın sağlıklı olması için beklenecek süre (sn) |
| `ODYSSEUS_ADMIN_PASSWORD` | rastgele 24 karakter | Sabit admin parolası kullanmak için |

Ayakta bırakılan stack'e giriş: kullanıcı `admin`, parola `upstream/.env` içindeki
`ODYSSEUS_ADMIN_PASSWORD` (dosya `chmod 600`, git dışı).

## Betik ne yapar?

**install** — dokümandaki adımlar birebir:
1. `git clone -b main` → `upstream/`
2. `cp .env.example .env` + `.env.test` değerleri, host `PUID/PGID`, rastgele admin parolası
3. `docker compose up -d` (GHCR imajı çekilir; çekilemezse compose yerel build'e düşer)
4. `/api/health` sağlıklı olana kadar bekleme; kullanılan imaj digest'lerini kaydetme

Compose her zaman `-p odysseus-test --project-directory upstream -f ./docker-compose.yml`
ile çağrılır; böylece göreli yollar (`./config/searxng`, `./scripts/...`, `./data`, `build: .`)
upstream klonuna göre çözülür ve tüm kaynaklar `odysseus-test` etiketiyle izole kalır.

**verify** — 20 kontrol:

| Grup | Kontroller |
|---|---|
| Servisler | 4 servis `running`, SearXNG healthcheck `healthy`, `RestartCount=0` |
| Ağ | Tüm portlar yalnızca `127.0.0.1`; container içinden `chromadb`, `searxng`, `ntfy` erişimi |
| Uygulama | `/api/health`, `/api/version`, `/login` |
| Kimlik doğrulama | Anonim `/api/auth/status`, yanlış parola → 401, admin login, oturumlu status (`is_admin`) |
| Yan servisler | ChromaDB heartbeat, ntfy health, SearXNG UI, SearXNG JSON arama (dış ağa bağlı → WARN) |
| Güvenlik/Veri | uvicorn'un `PUID` ile çalışması, `./data/auth.json` bind mount, restart sonrası login kalıcılığı |
| Loglar | `Traceback` sayısı (WARN) |

**uninstall** — `docker compose down -v --remove-orphans --rmi all`; doküman notuna göre
`down -v` bind mount'ları silmediği için `upstream/data`, `upstream/logs` ve `upstream/.env`
ayrıca silinir.

**verify-clean** — `odysseus-test` etiketli container/volume/network kalmadığı, stack
imajlarının silindiği, portların serbest kaldığı ve bind mount dizinlerinin yok olduğu doğrulanır.

## Notlar

- `docker compose down -v` ChromaDB vektörlerini (`chromadb-data`) siler; gerçek kurulumda
  önce `data/` ve volume yedeği alın. `data/` şifreleme anahtarı, vault ve token'ları içerir.
- `upstream/`, `.env` ve ham loglar (`reports/<run>/`) `.gitignore` ile repo dışında tutulur.
- Upstream proje AGPL-3.0 lisanslıdır; `docker-compose.yml` upstream reponun kopyasıdır.
