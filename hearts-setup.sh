#!/usr/bin/env bash
# Installs/updates Hearts Scorecard at hearts.jermins.com behind Caddy.
# Run ON the VPS:  curl -fsSL https://raw.githubusercontent.com/crimdow/hearts/main/hearts-setup.sh | tr -d '\r' | bash
set -e
REPO=https://github.com/crimdow/hearts/archive/refs/heads/main.tar.gz
SITE=/var/www/hearts
CF=/etc/caddy/Caddyfile
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo

[ -f "$CF" ] || { echo "Couldn't find $CF. Where is your Caddyfile? (If Caddy runs in Docker, tell Claude.)"; exit 1; }

echo "== Downloading the latest files from GitHub"
TMP=$(mktemp -d)
curl -fsSL "$REPO" | tar -xz -C "$TMP"
SRC="$TMP/hearts-main"

echo "== Copying site files to $SITE"
$SUDO mkdir -p "$SITE"
for f in index.html manifest.webmanifest favicon.ico icon.svg apple-touch-icon.png android-chrome-192.png android-chrome-512.png; do
  [ -f "$SRC/$f" ] && $SUDO cp "$SRC/$f" "$SITE/$f"
done
$SUDO chmod -R a+rX "$SITE"
rm -rf "$TMP"

if grep -q "hearts.jermins.com" "$CF"; then
  echo "== Caddy already has hearts.jermins.com - leaving the Caddyfile as is"
else
  echo "== Adding hearts.jermins.com to $CF (backup saved next to it)"
  $SUDO cp "$CF" "$CF.bak.$(date +%Y%m%d%H%M%S)"
  $SUDO tee -a "$CF" >/dev/null <<'CADDY'

hearts.jermins.com {
	root * /var/www/hearts
	file_server
	encode gzip
	@fresh path / /index.html /manifest.webmanifest
	header @fresh Cache-Control "no-cache"
}
CADDY
fi

echo "== Checking the Caddyfile"
$SUDO caddy validate --config "$CF" --adapter caddyfile
echo "== Reloading Caddy"
$SUDO systemctl reload caddy
echo
echo "Done. Open https://hearts.jermins.com (give HTTPS a minute the first time)."
