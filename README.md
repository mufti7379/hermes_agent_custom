# Hermes Agent di Docker — VPS Oracle bersama proyek lain

```
Internet ──► IP publik VPS :80/:443  (satu-satunya port terbuka, selain SSH)
                   │
        caddy_ssl  (milik banksampah-bsip-backend-FIX)
          │  jaringan "internal" 172.28.0.0/16 ── web_akun (banksampah)
          │  jaringan "proxy"    172.30.0.0/24 ── banksampahku-api / banksampahku-web (ResikforSchools)
          │                                    └─ hermes-dashboard:9119   (login 2 lapis)
          │
  hermes-gateway ── jaringan "hermes_egress" ──► keluar saja: API LLM, Telegram (polling)
          └── ./data  (HERMES_HOME: .env, config.yaml, memories, sessions)
```

- Gateway **tidak membuka port apa pun** → tidak bisa bentrok dengan proyek lain, tidak perlu ubah
  Security List Oracle / iptables.
- Dashboard hanya lewat Caddy yang sudah ada (domain + HTTPS + login), tidak pernah `ports:`.
- Proyek lain tidak diubah, kecuali menempel 1 blok situs (dashboard) di Caddyfile banksampah.

## 0. Cek kondisi VPS dulu

```bash
uname -m                         # aarch64 = Oracle Ampere (ARM) → lihat langkah 2b
free -h                          # sisa RAM; sesuaikan HERMES_MEM_LIMIT di .env
docker ps --format '{{.Names}}\t{{.Ports}}'          # hanya caddy_ssl yang punya 80/443
docker network ls | grep proxy                        # jaringan bersama sudah ada?
docker inspect caddy_ssl --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
#   → harus memuat "proxy" (jalur Caddy → dashboard)
```

## 1. Pastikan caddy_ssl tersambung ke jaringan `proxy` (wajib: jalur ke dashboard)

Kalau `proxy` belum ada: `docker network create --subnet 172.30.0.0/24 proxy`.

Kalau caddy_ssl belum tersambung, cara cepat: `docker network connect proxy caddy_ssl`.

> **Penting:** di `docker-compose.yaml` banksampah (salinan lokal), service `caddy` hanya punya jaringan
> `internal`. Sambungan yang dibuat manual dengan `docker network connect` **hilang** setiap container itu
> dibuat ulang (`docker compose up -d` setelah ubah compose, `--force-recreate`, ganti image) → ResikforSchools
> *dan* Hermes dashboard ikut putus (502). Solusi permanennya: tambahkan `proxy` di compose banksampah
> (`networks: [internal, proxy]` di service caddy + `proxy: {external: true}` di blok `networks:`).
> Cek dulu versi compose di VPS, mungkin sudah ditambahkan saat deploy ResikforSchools.

## 2. Salin proyek ke VPS

Dari Windows (PowerShell, folder `d:\.ssh`):

```powershell
scp -i ssh_etos_oracle -r hermes-agent-build/compose.yml hermes-agent-build/.env.example hermes-agent-build/caddy ubuntu@IP_VPS:/tmp/hermes/
```

Di VPS:

```bash
sudo mkdir -p /opt/hermes-agent && sudo chown ubuntu:ubuntu /opt/hermes-agent
cp -r /tmp/hermes/. /opt/hermes-agent/ && cd /opt/hermes-agent
mkdir -p data && chmod 700 data          # berisi API key: jangan bisa dibaca user lain
cp .env.example .env && chmod 600 .env
id -u; id -g                             # isi HERMES_UID / HERMES_GID di .env dengan angka ini
nano .env
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

1. **Allowlist** ada di `.env` compose (`HERMES_ALLOWED_USERS`, ID numerik, pisahkan koma), **bukan** di
   `data/.env`. Compose menolak start kalau kosong, dan `compose.yml` mengunci semua mode
   "izinkan semua" ke `false`, jadi tidak bisa dilonggarkan dari `config.yaml`.
2. **Matikan pairing.** Defaultnya orang asing yang DM bot mendapat kode pairing (tetap butuh persetujuanmu,
   tapi lebih baik tidak ditanggapi sama sekali):
   ```bash
   docker compose run --rm gateway config set unauthorized_dm_behavior ignore
   grep unauthorized_dm_behavior data/config.yaml     # pastikan tersimpan
   ```
   (`ignore` = diam saja, `decline` = balas sekali "ditolak" lalu diam 24 jam.)
3. Kalau dulu pernah approve pairing: `docker compose exec gateway hermes pairing list` →
   `hermes pairing revoke telegram <ID>` untuk yang tidak dikenal.

## 4. Jalankan

```bash
docker compose up -d
docker compose logs -f gateway                 # tunggu sampai platform "connected"
docker stats --no-stream                       # cek RAM: MySQL banksampah tetap kebagian
```

Kirim pesan ke bot Telegram-mu. Kalau muncul kode pairing:
`docker compose exec gateway hermes pairing approve telegram KODE`

## 5. Dashboard (selalu jalan bersama gateway)

**A. Lewat domain (Caddy yang sudah ada)**

1. Isi `DASHBOARD_USER` dan `DASHBOARD_PASSWORD` (`openssl rand -hex 24`) di `.env`.
2. Sudah ikut jalan di langkah 4 → `docker compose logs dashboard` tidak boleh error auth.
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
   `reload` tidak memutus situs banksampah & ResikforSchools; kalau `validate` gagal, tidak ada yang berubah.

**B. Tanpa domain (paling aman):** lewati langkah A.3–A.5 (tanpa DNS & Caddy), lalu tunnel SSH ke IP container-nya:

```bash
docker inspect hermes-dashboard-1 --format '{{(index .NetworkSettings.Networks "proxy").IPAddress}}'
# di laptop:
ssh -i ~/.ssh/ssh_etos_oracle -L 9119:172.30.0.X:9119 ubuntu@IP_VPS   # buka http://localhost:9119
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

Bot: minta teman (ID yang **tidak** ada di `HERMES_ALLOWED_USERS`) mengirim pesan ke bot → tidak dibalas,
dan `docker compose logs gateway | grep -i unauthorized` mencatat penolakannya.

## 6. Operasional (di `/opt/hermes-agent`)

| Tugas | Perintah |
| :--- | :--- |
| Log | `docker compose logs -f gateway` |
| Tambah/cabut pengguna bot | ubah `HERMES_ALLOWED_USERS` di `.env` → `docker compose up -d` (container dibuat ulang dengan env baru) |
| Ganti password dashboard | lapis 1: hash baru di Caddyfile banksampah → `caddy reload`; lapis 2: `DASHBOARD_PASSWORD` di `.env` → `docker compose up -d` |
| Ubah setting | `docker compose exec gateway hermes config set KUNCI nilai` lalu `docker compose restart gateway` |
| Update | ganti tag di `.env` → `docker compose pull && docker compose up -d` |
| Backup | `docker compose stop && tar czf hermes-$(date +%F).tgz data && docker compose start` |
| Hentikan | `docker compose down` (data aman di `./data`, proyek lain tidak tersentuh) |

## 7. Aturan keamanan

- **Jangan** tambah `ports:` di compose ini (Docker mem-bypass firewall).
- **Jangan** mount `/var/run/docker.sock` atau folder proyek lain ke container Hermes: agent bisa menjalankan
  perintah shell, jadi apa pun yang terlihat dari container bisa dibaca/dihapus olehnya.
- **Jangan** jalankan dua gateway terhadap folder `data` yang sama (state.db SQLite bisa rusak).
- Gateway sengaja **tidak** dimasukkan ke jaringan `proxy`/`internal`, jadi tidak bisa memanggil
  `banksampahku-api`, `web_akun`, database, dll. Jangan tambahkan jaringan itu ke service `gateway`.
- Jangan set `HERMES_YOLO_MODE=1` dan biarkan `security.allow_private_urls` mati: kalau aktif, agent masih
  bisa menjangkau port yang listen di host lewat IP privat (mis. 172.x.0.1).
