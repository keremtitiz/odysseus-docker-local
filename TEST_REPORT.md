# Odysseus Docker kurulum testi — rapor

**Tarih:** 2026-11-17 · **Sonuç:** ✅ BAŞARILI — 45 PASS / 2 WARN / 0 FAIL · **Süre:** 222 sn (kurulum → doğrulama → kaldırma)

Ayrıntılı tablo: [`reports/LATEST.md`](reports/LATEST.md)

## Test edilen

| | |
|---|---|
| Kaynak doküman | https://odysseusai.dev/install/docker |
| Upstream | `odysseus-dev/odysseus` `main` @ `9d0d3720f4ca181d87bef94da826d730acc6d483` |
| Uygulama | Odysseus `1.0.3` (build `0.20.19`) |
| Odysseus imajı | `ghcr.io/odysseus-dev/odysseus:latest` → `sha256:5117c5e07e5976095ce213e601277ff372e0387a67de34c5fd59a3de723e6113` |
| Yan servisler | `chromadb/chroma:1.5.9`, `searxng/searxng:2026.10.24-ef0ec03da`, `binwiederhier/ntfy:v2.32.0` (upstream compose'da digest ile pinli) |
| Host | macOS 27.2 / Apple Silicon (arm64), Docker Desktop — Engine 29.8.2, Compose 5.5.1, VM: 10 CPU / 7.7 GiB RAM |

## Özet sonuçlar

| Faz | Sonuç | Öne çıkanlar |
|---|---|---|
| Ön koşullar | 9/9 | Docker + Compose V2, RAM ≥ 8 GB, disk ≥ 20 GB, 4 port boş |
| Kurulum | 5 PASS, 2 WARN | Clone → `.env` → `docker compose up -d` 173 sn (imaj indirme dahil); uygulama ilk açılışta ~35 sn sonra sağlıklı |
| Doğrulama | 20/20 | 4 servis çalışıyor, crash-loop yok, portlar yalnızca loopback; health/version/login; auth (401 / login / admin oturumu); ChromaDB, SearXNG (JSON arama dahil), ntfy; container içi servis ağı; uvicorn root değil `PUID` ile çalışıyor; restart sonrası auth kalıcı; logda Traceback yok |
| Kaldırma | 2/2 | `down -v --remove-orphans --rmi all` + `data/`, `logs/`, `.env` silindi |
| Temizlik doğrulaması | 7/7 | 0 container / volume / network; testin çektiği 3 imaj silindi, önceden var olan imaj korundu; portlar serbest |

## Bulgular

1. **Upstream compose uyarısı (WARN, düşük):** `docker-compose.yml` içinde
   `ODYSSEUS_TTS_CACHE_MAX_BYTES=${ODYSSEUS_TTS_CACHE_MAX_BYTES}` satırının varsayılan değeri yok;
   diğer tüm değişkenler `:-` ile varsayılan alıyor. Her `docker compose` komutu
   `The "ODYSSEUS_TTS_CACHE_MAX_BYTES" variable is not set` uyarısı veriyor. Uygulama boş değerle
   sorunsuz açılıyor. Öneri (upstream'e): `${ODYSSEUS_TTS_CACHE_MAX_BYTES:-524288000}`.
2. **Önceden var olan imaj (WARN, bilgi):** Pinli `chromadb/chroma:1.5.9` digest'i host'taki eski
   `chromadb/chroma:latest` ile aynı imaj. Compose bu yüzden indirmedi ve `--rmi all` onu (başka
   etiketle kullanıldığı için) silmedi. Bu doğru davranış; betik önceden var olan imajları kaydedip
   kaldırmada korur.
3. **Bellek sınırda:** Docker Desktop VM'ine 8.3 GB (7.7 GiB) ayrılmış; doküman minimumu 8 GB.
   Temel stack için yeterli; yerel model çalıştırılacaksa doküman 16 GB+ öneriyor.
4. **`source_commit: "unknown"`:** GHCR imajı `/api/version`'da kaynak commit bilgisi döndürmüyor;
   hangi commit'ten build edildiği yalnızca imaj digest'i ile izlenebiliyor.
5. **İlk açılış süresi:** `up -d` tamamlandıktan sonra `/api/health` ~35 sn sonra yanıt veriyor;
   SearXNG healthcheck'i Odysseus'un başlamasını geciktiriyor (`depends_on: service_healthy`).

## Doğrulanan doküman iddiaları

- [x] Compose 4 servis başlatıyor (Odysseus, ChromaDB, SearXNG, ntfy), hepsi `127.0.0.1`'e bağlı
- [x] UI `localhost:7011`'de, container içinde 7000
- [x] `ODYSSEUS_ADMIN_PASSWORD` ilk açılışta admin parolasını belirliyor; kullanıcı `admin`
- [x] Admin hesabı `data/auth.json` içinde (bind mount) ve restart sonrası korunuyor
- [x] Container `PUID/PGID` ile çalışıyor
- [x] `docker compose down -v` named volume'ları siliyor, `./data`'yı **silmiyor** (betik ayrıca temizliyor)

## Tekrar çalıştırma

```bash
./odysseus-test.sh full
```
