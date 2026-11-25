#!/bin/bash
# Pasang/perbarui satu blok situs di Caddyfile milik caddy_ssl. Aman diulang: blok lama domain itu diganti.
# Salinan divalidasi dulu di container; kalau gagal, Caddyfile asli tidak disentuh.
#   bash caddy/pasang-situs.sh 9router.mufutirf.my.id caddy/9router.caddy
set -eu

DOMAIN=${1:?isi domain}
FILE=${2:?isi file .caddy}
CF=${CF:-/home/ubuntu/etos/Caddyfile}
NEW=$(mktemp)
trap 'rm -f "$NEW"' EXIT
stop() { echo "STOP: $1"; exit 1; }

blok() { awk -v d="$DOMAIN" '$1==d || $1==d"{" {n++} END {print n+0}' "$1"; }
situs() { awk -v d="$DOMAIN" '/^[^ \t#}]/ && /\{[ \t\r]*$/ && $1!="{" && $1!=d && $1!=d"{" {print $1}' "$1"; }

[ "$(blok "$FILE")" = 1 ] || stop "$FILE harus berisi tepat 1 blok $DOMAIN"
grep -qE '^[[:space:]]*admin \$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}[[:space:]]*$' "$FILE" \
  || stop "HASH_BCRYPT di $FILE belum diganti (atau terpotong)"
docker exec caddy_ssl cat /etc/caddy/Caddyfile | cmp -s - "$CF" || stop "Caddy melihat file yang berbeda dari $CF"

# Buang blok lama domain ini, lalu tambahkan yang baru di akhir
awk -v d="$DOMAIN" '
  !skip && ($1==d || $1==d"{") { skip=1; n=0 }
  skip { a=gsub(/\{/,"{"); b=gsub(/\}/,"}"); n+=a-b; if (n<=0 && (a||b)) skip=0; next }
  { print }' "$CF" > "$NEW"
[ "$(situs "$CF")" = "$(situs "$NEW")" ] || stop "situs lain ikut berubah"
echo >> "$NEW"
grep -v '^#' "$FILE" >> "$NEW"

docker exec -i caddy_ssl sh -c 'cat > /tmp/Caddyfile.baru' < "$NEW"
docker exec caddy_ssl caddy validate --config /tmp/Caddyfile.baru --adapter caddyfile \
  || stop "tidak valid, Caddyfile asli TIDAK diubah"

BAK="$CF.bak-$(date +%Y%m%d-%H%M%S)"
cp "$CF" "$BAK"
cat "$NEW" > "$CF" # bukan cp/mv: Caddyfile di-mount sebagai satu file
docker exec caddy_ssl caddy reload --force --config /etc/caddy/Caddyfile
echo "SELESAI. Backup: $BAK"
