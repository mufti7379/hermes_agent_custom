# Hermes Agent di Docker — VPS Oracle bersama proyek lain

```
Internet ──► IP publik VPS :80/:443  (satu-satunya port terbuka, selain SSH)
                   │
        caddy_ssl  (milik banksampah-bsip-backend-FIX)
          │  jaringan "internal" 172.28.0.0/16 ── web_akun (banksampah)
          │  jaringan "proxy"    172.30.0.0/24 ── banksampahku-api / banksampahku-web (ResikforSchools)
          │  jaringan "hermes-edge" (khusus)   ── hermes-gateway-1: gateway + dashboard :9119 (login 2 lapis)
          │
  hermes-gateway-1 ── jaringan "router" ── hermes-9router-1:20128 ──► keluar: provider AI
          │ ──► keluar: Telegram (polling)
          └── ./data  (HERMES_HOME: .env, config.yaml, memories, sessions)
```

- Gateway **tidak membuka port apa pun** → tidak bisa bentrok dengan proyek lain, tidak perlu ubah
  Security List Oracle / iptables.
- Dashboard hanya lewat Caddy yang sudah ada (domain + HTTPS + login), tidak pernah `ports:`.
- Proyek lain tidak diubah, kecuali dua hal di banksampah: 1 blok situs di Caddyfile dan `caddy_ssl`
  disambungkan ke jaringan `hermes-edge`.

## 0. Cek kondisi VPS dulu

```bash
uname -m                         # aarch64 = Oracle Ampere (ARM) → lihat langkah 2b
free -h                          # sisa RAM; sesuaikan HERMES_MEM_LIMIT di .env
docker ps --format '{{.Names}}\t{{.Ports}}'          # hanya caddy_ssl yang punya 80/443
docker network ls | grep hermes-edge                  # sudah pernah dibuat?
docker inspect caddy_ssl --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
#   → catat hasilnya: jaringan yang sekarang dipakai caddy_ssl tidak boleh ada yang hilang
```

## 1. Buat jaringan `hermes-edge` dan sambungkan caddy_ssl (wajib: jalur ke dashboard)

```bash
docker network create hermes-edge
docker network connect hermes-edge caddy_ssl      # tanpa restart, jaringan lama tetap tersambung
```

Dashboard **tidak** masuk jaringan `proxy`: tab Chat-nya bisa menjalankan perintah, dan dari `proxy`
perintah itu bisa memanggil `banksampahku-api` / `banksampahku-web`.

> **Penting:** sambungan dari `docker network connect` **hilang** setiap `caddy_ssl` dibuat ulang
> (`--force-recreate`, ganti image, ubah compose) → dashboard 502. Solusi permanen di compose banksampah:
> tambahkan `hermes-edge` ke `networks:` service `caddy` (biarkan jaringan lainnya) dan
> `hermes-edge: {external: true}` di blok `networks:` paling bawah.
> Salinan lokal compose banksampah juga belum memuat `proxy`. Kalau versi di VPS sama, ResikforSchools
> punya masalah serupa, jadi tambahkan `proxy` sekalian.

## 2. Salin proyek ke VPS

Dari Windows (PowerShell, folder `d:\.ssh`):

```powershell
ssh -i ssh_etos_oracle ubuntu@IP_VPS "mkdir -p /tmp/hermes"
scp -i ssh_etos_oracle -r hermes-agent-build/compose.yml hermes-agent-build/.env.example hermes-agent-build/managed.env.example hermes-agent-build/caddy ubuntu@IP_VPS:/tmp/hermes/
```

Di VPS:

```bash
sudo mkdir -p /opt/hermes-agent && sudo chown ubuntu:ubuntu /opt/hermes-agent
cp -r /tmp/hermes/. /opt/hermes-agent/ && cd /opt/hermes-agent
mkdir -p data && chmod 700 data          # berisi API key: jangan bisa dibaca user lain
cp .env.example .env && chmod 600 .env
id -u; id -g                             # isi HERMES_UID / HERMES_GID di .env dengan angka ini
nano .env

mkdir -p managed && cp managed.env.example managed/.env && chmod 755 managed && chmod 644 managed/.env
nano managed/.env                        # kunci akses bot: ganti SEMUA 123456789 dengan ID kamu
docker compose config --quiet && echo OK # cek sintaks & variabel wajib sebelum lanjut
```

### 2b. VPS ARM (aarch64) dan image tidak punya arm64

```bash
docker manifest inspect nousresearch/hermes-agent:stable | grep -A1 '"architecture"'
# Kalau tidak ada "arm64":
git clone https://github.com/NousResearch/hermes-agent.git /opt/hermes-src
docker build -t hermes-agent:local /opt/hermes-src
# lalu di .env: HERMES_IMAGE=hermes-agent:local
```

## 3. Setup wizard (sekali)

```bash
docker compose run --rm gateway setup          # pilih provider model + isi API key
docker compose run --rm gateway gateway setup  # sambungkan Telegram/Discord/Slack
```

Hasilnya tersimpan di `data/.env` dan `data/config.yaml`.

### Auth bot (siapa yang boleh chat)

1. **Allowlist** ada di `managed/.env` (dibuat di langkah 2), dipasang read-only ke `/etc/hermes`. Hermes
   membacanya paling akhir, jadi menang atas `data/.env`. Kalau wizard menampilkan *"managed by your
   administrator"* saat mengisi allowlist, itu normal: kuncinya bekerja.
   Template mengunci **Telegram dan Discord**. Untuk platform lain (Slack, WhatsApp, dll.) tambahkan
   `<PLATFORM>_ALLOWED_USERS` dan `<PLATFORM>_ALLOW_ALL_USERS=false` di file yang sama.
   Yang **tidak** terkunci: pairing yang disetujui (tersimpan di `data/`) dan pengaturan akses di
   `data/config.yaml`, misalnya `group_allowed_chats`. Agent bisa menulis keduanya, jadi hanya izinkan orang
   yang kamu percaya dan cek sesekali dengan perintah di nomor 3.
2. **Pairing.** Selama allowlist terisi, Hermes otomatis tidak membalas orang asing, kecuali wizard mengatur
   platform tertentu ke `pair`/`decline`. Pengaman tambahan:
   ```bash
   docker compose run --rm gateway config set unauthorized_dm_behavior ignore
   grep unauthorized_dm_behavior data/config.yaml     # pastikan tersimpan
   ```
   (`ignore` = diam saja, `decline` = balas sekali "ditolak" lalu diam 24 jam.)
3. Kalau dulu pernah approve pairing: `docker compose exec gateway hermes pairing list` →
   `docker compose exec gateway hermes pairing revoke telegram <ID>` untuk yang tidak dikenal. Cek juga
   `grep -nE 'allow|pair' data/config.yaml`.

## 4. Jalankan

```bash
docker compose up -d
docker compose logs -f gateway                 # tunggu sampai platform "connected"
docker stats --no-stream                       # cek RAM: MySQL banksampah tetap kebagian
```

Kirim pesan ke bot Telegram-mu. Kalau bot diam, cek ID-mu di `managed/.env` (angka, bukan @username).

## 5. Dashboard (selalu jalan bersama gateway)

**A. Lewat domain (Caddy yang sudah ada)**

1. Isi `DASHBOARD_USER` dan `DASHBOARD_PASSWORD` (`openssl rand -hex 24`) di `.env`.
2. Sudah ikut jalan di langkah 4 → `docker compose logs gateway | grep -i dashboard` tidak boleh error auth.
3. DNS: record A `hermes.mufutirf.my.id` → IP VPS (Cloudflare: *DNS only* dulu).
4. Buat hash password **lapis 1** (login Caddy) dan pasang di `caddy/hermes.caddy`:
   ```bash
   docker exec -it caddy_ssl caddy hash-password         # ketik password (beda dari DASHBOARD_PASSWORD)
   nano /opt/hermes-agent/caddy/hermes.caddy             # ganti HASH_BCRYPT dengan hasil $2a$14$...
   ```
5. Tempel isi `caddy/hermes.caddy` ke Caddyfile banksampah. Caddyfile itu di-mount sebagai **satu file**;
   editor yang menulis file baru (mis. vim/sed -i) membuat container tetap melihat versi lama, jadi pakai
   `cat >>`:
   ```bash
   cd /path/ke/banksampah-bsip-backend-FIX
   cp Caddyfile Caddyfile.bak-$(date +%F)
   cat /opt/hermes-agent/caddy/hermes.caddy >> Caddyfile
   docker exec caddy_ssl caddy validate --config /etc/caddy/Caddyfile \
     && docker exec caddy_ssl caddy reload --config /etc/caddy/Caddyfile
   ```
   `reload` tidak memutus situs banksampah & ResikforSchools. Kalau `validate` **gagal**, Caddy masih jalan
   dengan config lama, tapi Caddyfile-nya sudah rusak: begitu `caddy_ssl` restart, **semua situs mati**.
   Langsung kembalikan:
   ```bash
   cat Caddyfile.bak-$(date +%F) > Caddyfile       # pakai cat, bukan cp/mv, supaya file mount tetap sama
   ```

**B. Tanpa domain (paling aman):** lewati langkah A.3–A.5 (tanpa DNS & Caddy), lalu tunnel SSH ke IP container-nya:

```bash
docker inspect hermes-gateway-1 --format '{{(index .NetworkSettings.Networks "hermes-edge").IPAddress}}'
# di laptop (ganti IP_DASHBOARD dengan hasil di atas):
ssh -i ~/.ssh/ssh_etos_oracle -L 9119:IP_DASHBOARD:9119 ubuntu@IP_VPS   # buka http://localhost:9119
```

## 5b. Uji auth (wajib sebelum dianggap selesai)

```bash
# Dashboard tanpa login → harus 401 dari Caddy (Hermes tidak tersentuh)
curl -sI https://hermes.mufutirf.my.id | head -1
# Password salah → tetap 401
curl -sI -u admin:salah https://hermes.mufutirf.my.id | head -1
# Login Caddy benar → sampai ke Hermes, yang meminta login lapis 2 (bukan langsung isi dashboard)
curl -sI -u admin:PASSWORD_CADDY https://hermes.mufutirf.my.id | head -1
# Dashboard tidak bisa diakses langsung lewat IP:port
curl -m 5 http://IP_VPS:9119 ; echo "exit=$?"       # harus timeout / connection refused
```

Isolasi: container Hermes tidak boleh mengenal proyek lain (harus muncul `gaierror`, bukan alamat IP):

```bash
for h in banksampahku-api web_akun bsip_data; do
  echo "$h: $(docker compose exec -T gateway /opt/hermes/.venv/bin/python -c \
    "import socket; print(socket.gethostbyname('$h'))" 2>&1 | tail -1)"
done
```

Kunci akses bot:

```bash
# Harus mencetak ID kamu dan ALLOW_ALL_USERS false (kalau {} → kunci TIDAK terpasang, jangan lanjut)
docker compose exec -T -w /opt/hermes gateway /opt/hermes/.venv/bin/python -c \
  "from hermes_cli.managed_scope import load_managed_env; print(load_managed_env())"
# Harus gagal: "Read-only file system"
docker compose exec -T gateway sh -c 'touch /etc/hermes/uji'
```

Bot: minta teman (ID yang **tidak** ada di `managed/.env`) mengirim pesan ke bot → tidak dibalas,
dan `docker compose logs gateway | grep -i unauthorized` mencatat penolakannya.

## 5c. 9Router (provider AI untuk Hermes)

1. Isi `ROUTER_PASSWORD` dan `ROUTER_API_KEY_SECRET` di `.env`, lalu `docker compose up -d`.
2. Buka dashboard. Lewat domain: buat record A `9router.mufutirf.my.id` → IP VPS (*DNS only*), ganti `HASH_BCRYPT`
   di `caddy/9router.caddy`, lalu jalankan `bash caddy/pasang-situs.sh 9router.mufutirf.my.id caddy/9router.caddy`.
   Skrip itu memvalidasi salinan dulu; kalau tidak valid, Caddyfile asli tidak disentuh.
   **Jangan** buka lewat `http://IP:20128` (tanpa HTTPS, melewati Caddy). Atau lewat tunnel SSH:
   ```bash
   docker inspect hermes-9router-1 --format '{{(index .NetworkSettings.Networks "hermes_router").IPAddress}}'
   # di laptop (ganti IP_ROUTER):
   ssh -i ~/.ssh/ssh_etos_oracle -L 20128:IP_ROUTER:20128 ubuntu@IP_VPS   # buka http://localhost:20128
   ```
   Login dengan `ROUTER_PASSWORD`. IP bisa berubah setelah container dibuat ulang.
3. Menu **Providers**: sambungkan provider. Menu **Endpoint**: buat API key khusus Hermes, dan pastikan
   **Require API key** menyala.
4. Sambungkan Hermes:
   ```bash
   cp data/config.yaml data/config.yaml.bak-sebelum-9router
   docker compose exec gateway hermes model        # pilih "Custom endpoint"
   #   Base URL : http://9router:20128/v1
   #   API key  : API key dari langkah 3
   #   Model    : salin nama lengkap dari dashboard 9Router, konteks minimal 64K
   docker compose restart gateway
   ```
5. Kembali ke provider lama: `cat data/config.yaml.bak-sebelum-9router > data/config.yaml` lalu
   `docker compose restart gateway`.

`REQUIRE_API_KEY` di README 9Router tidak dibaca kodenya (0.5.123); yang berlaku adalah tombol di menu Endpoint.
Jangan aktifkan fitur Tunnel/Tailscale/Cloud di 9Router: itu membukanya ke internet.

## 5d. Proxy Cloudflare (awan oranye) untuk Hermes & 9Router

Template di `caddy/` memakai Origin Certificate Cloudflare dan menolak koneksi yang tidak lewat Cloudflare.
Petunjuk *DNS only* di langkah 5 dan 5c hanya untuk cara lama (sertifikat Let's Encrypt).

1. Cloudflare → SSL/TLS → Origin Server → Create Certificate (RSA, 15 tahun) untuk kedua hostname. Simpan sebagai
   `cert.pem` dan `key.pem`, lalu salin ke volume Caddy:
   ```bash
   docker exec caddy_ssl mkdir -p /data/cf-origin
   docker cp cert.pem caddy_ssl:/data/cf-origin/cert.pem && docker cp key.pem caddy_ssl:/data/cf-origin/key.pem
   docker exec caddy_ssl sh -c 'chown root:root /data/cf-origin/*; chmod 700 /data/cf-origin; chmod 600 /data/cf-origin/*'
   ```
2. Mode SSL untuk kedua hostname: **Full (strict)** (pakai Configuration Rule supaya subdomain lain tidak berubah).
   Cache Rule: **Bypass cache** untuk kedua hostname.
3. Ubah kedua record DNS ke **Proxied**, lalu pasang bloknya:
   ```bash
   bash caddy/pasang-situs.sh hermes.mufutirf.my.id caddy/hermes.caddy
   bash caddy/pasang-situs.sh 9router.mufutirf.my.id caddy/9router.caddy
   ```
Kembali ke awan abu-abu = hapus baris `tls` dan `abort` dulu, kalau tidak situsnya tidak bisa dibuka.

## 6. Operasional (di `/opt/hermes-agent`)

| Tugas | Perintah |
| :--- | :--- |
| Log | `docker compose logs -f gateway` |
| Tambah/cabut pengguna bot | ubah `managed/.env` (semua baris yang memuat ID) → `docker compose restart` |
| Ganti password dashboard | lapis 1: hash baru di Caddyfile banksampah → `caddy reload`; lapis 2: `DASHBOARD_PASSWORD` di `.env` → `docker compose up -d` |
| Ubah setting | `docker compose exec gateway hermes config set KUNCI nilai` lalu `docker compose restart gateway` |
| Update | ganti tag di `.env` → `docker compose pull && docker compose up -d` |
| Backup | `docker compose stop && tar czf hermes-$(date +%F).tgz data managed router-data .env; docker compose start` |
| Hentikan | `docker compose down` (data aman di `./data`, proyek lain tidak tersentuh) |

## 7. Aturan keamanan

- **Jangan** tambah `ports:` di compose ini (Docker mem-bypass firewall).
- **Jangan** mount `/var/run/docker.sock` atau folder proyek lain ke container Hermes: agent bisa menjalankan
  perintah shell, jadi apa pun yang terlihat dari container bisa dibaca/dihapus olehnya.
- **Jangan** jalankan dua gateway terhadap folder `data` yang sama (state.db SQLite bisa rusak).
- Container Hermes sengaja tidak dimasukkan ke jaringan `proxy`/`internal`, jadi tidak bisa memanggil
  `banksampahku-api`, `web_akun`, database, dll. Jangan tambahkan jaringan itu, dan jangan
  masukkan container lain selain `caddy_ssl` ke `hermes-edge`.
- Login dashboard = akses menjalankan perintah (tab Chat) + melihat API key. Perlakukan passwordnya seperti
  password SSH.
- Jangan set `HERMES_YOLO_MODE=1` dan biarkan `security.allow_private_urls` mati: kalau aktif, agent masih
  bisa menjangkau port yang listen di host lewat IP privat (mis. 172.x.0.1).
