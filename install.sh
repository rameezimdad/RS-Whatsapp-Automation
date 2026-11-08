#!/usr/bin/env bash
# Developed by Mohammad Rameez Imdad (Rameez Scripts)
# WhatsApp: https://wa.me/923435347417 (For Custom Projects)
# YouTube: https://www.youtube.com/@rameezimdad (Subscribe for more!)
#
# RS WhatsApp on a Linux VPS (Ubuntu / Debian, x64): installs it, runs it as a service, puts HTTPS on your own domain.
#   curl -fsSL https://raw.githubusercontent.com/rameezimdad/RS-Whatsapp-Automation/main/install.sh | sudo bash
# Run it again to update (your data and password stay). Options:
#   --domain wa.example.com   your domain (its DNS A record points at this server)
#   --port 8686               the app's local port (Caddy sends the domain to it)
#   --no-caddy                you run your own web server in front (proxy it to 127.0.0.1:<port>)
#   --password                set a new password      --update   update only, ask nothing
#   --uninstall               remove the app (data kept)   --purge   remove the data too
set -euo pipefail

REPO="rameezimdad/RS-Whatsapp-Automation"
RAW="https://raw.githubusercontent.com/$REPO/main/install.sh"
APP=/opt/rs-whatsapp
DATA=/var/lib/rs-whatsapp
RUSER=rswa
ENVF=/etc/rs-whatsapp.env
CADDY_SITE=/etc/caddy/rs-whatsapp.caddy
PUB="-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAAVuUibJfj7Nxl10juI0woBLs6Js++h5h9S7iJRRST3M=
-----END PUBLIC KEY-----"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
tty_ok() { [ -r /dev/tty ] && [ -w /dev/tty ]; }
ask() { local v=""; tty_ok && read -r -p "$1" v < /dev/tty || true; printf '%s' "$v"; }
ask_secret() { local v=""; tty_ok && { read -r -s -p "$1" v < /dev/tty; echo > /dev/tty; } || true; printf '%s' "$v"; }

DOMAIN="${RSWA_DOMAIN:-}"; PORT="${RSWA_PORT:-}"; CADDY=1; NEWPASS=0; UPDATE=0; UNINSTALL=0; PURGE=0; PASSWORD="${RSWA_PASSWORD:-}"
while [ $# -gt 0 ]; do
	case "$1" in
		--domain) DOMAIN="${2:-}"; shift ;;
		--port) PORT="${2:-}"; shift ;;
		--no-caddy) CADDY=0 ;;
		--password) NEWPASS=1 ;;
		--update) UPDATE=1 ;;
		--uninstall) UNINSTALL=1 ;;
		--purge) UNINSTALL=1; PURGE=1 ;;
		*) die "Unknown option: $1" ;;
	esac
	shift
done

[ "$(id -u)" = 0 ] || die "Run it as root:  curl -fsSL $RAW | sudo bash"
[ "$(uname -m)" = "x86_64" ] || die "This server is $(uname -m). RS WhatsApp runs on x64 (x86_64) servers."
command -v apt-get >/dev/null || die "Ubuntu or Debian is needed (apt-get not found)."
command -v systemctl >/dev/null || die "systemd is needed."

# ---------- remove ----------
if [ "$UNINSTALL" = 1 ]; then
	say "Removing RS WhatsApp"
	systemctl disable --now rs-whatsapp.service rs-whatsapp-update.timer 2>/dev/null || true
	rm -f /etc/systemd/system/rs-whatsapp.service /etc/systemd/system/rs-whatsapp-update.service /etc/systemd/system/rs-whatsapp-update.timer /usr/local/bin/rs-whatsapp "$ENVF"
	systemctl daemon-reload
	if [ -f "$CADDY_SITE" ]; then rm -f "$CADDY_SITE"; sed -i '\#import /etc/caddy/rs-whatsapp.caddy#d' /etc/caddy/Caddyfile 2>/dev/null || true; systemctl reload caddy 2>/dev/null || true; fi
	rm -rf "$APP"
	if [ "$PURGE" = 1 ]; then rm -rf "$DATA"; userdel "$RUSER" 2>/dev/null || true; say "Removed, data too."; else say "Removed. Your data is still in $DATA (use --purge to delete it)."; fi
	exit 0
fi

FRESH=1; [ -f "$DATA/data/server.json" ] && FRESH=0
[ -f "$ENVF" ] && . "$ENVF" 2>/dev/null || true
PORT="${PORT:-${RSWA_PORT:-8686}}"
DOMAIN="${DOMAIN:-${RSWA_DOMAIN:-}}"
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || die "The port must be a number."

# ---------- questions (first install, or --password) ----------
if [ "$UPDATE" = 0 ]; then
	if [ "$CADDY" = 1 ] && [ -z "$DOMAIN" ]; then
		echo
		echo "Your domain for RS WhatsApp, e.g. wa.yourbusiness.com. Its DNS A record must point at this server's IP."
		DOMAIN="$(ask "Domain: ")"
		[ -n "$DOMAIN" ] || die "A domain is needed for HTTPS. Or run with --no-caddy and put your own web server in front."
	fi
	DOMAIN="$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##')"
	[ -z "$DOMAIN" ] || [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "That domain does not look right: $DOMAIN"
	if [ "$FRESH" = 1 ] || [ "$NEWPASS" = 1 ]; then
		if [ -z "$PASSWORD" ]; then
			echo
			echo "A password for signing in to RS WhatsApp in the browser (at least 10 characters)."
			PASSWORD="$(ask_secret "Password: ")"
			[ "${#PASSWORD}" -ge 10 ] || die "Use at least 10 characters."
			[ "$PASSWORD" = "$(ask_secret "Same password again: ")" ] || die "The two passwords are not the same."
		fi
		[ "${#PASSWORD}" -ge 10 ] || die "The password needs at least 10 characters."
	fi
fi

# ---------- system packages ----------
say "Installing what the app needs"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
pick() { for n in "$@"; do apt-cache show "$n" >/dev/null 2>&1 && { echo "$n"; return; }; done; }
PKGS="curl ca-certificates tar gzip openssl libnss3 libnspr4 libdrm2 libgbm1 libxss1 libxshmfence1 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libxfixes3 libpango-1.0-0 libcairo2 libdbus-1-3 libexpat1 libx11-xcb1"
for alts in "libasound2t64 libasound2" "libgtk-3-0t64 libgtk-3-0" "libatk1.0-0t64 libatk1.0-0" "libatk-bridge2.0-0t64 libatk-bridge2.0-0" "libcups2t64 libcups2"; do
	p="$(pick $alts)"; [ -n "$p" ] && PKGS="$PKGS $p"
done
apt-get install -y -qq $PKGS >/dev/null

# ---------- the latest release, checked ----------
say "Getting the latest RS WhatsApp"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -nE 's/.*"tag_name": *"([^"]+)".*/\1/p' | head -1)"
[ -n "$TAG" ] || die "Could not read the latest release from GitHub."
curl -fsSL "https://github.com/$REPO/releases/download/$TAG/linux.json" -o "$TMP/linux.json" || die "Release $TAG has no Linux build yet."
V="$(sed -nE 's/.*"version": *"([^"]+)".*/\1/p' "$TMP/linux.json")"
F="$(sed -nE 's/.*"file": *"([^"]+)".*/\1/p' "$TMP/linux.json")"
SHA="$(sed -nE 's/.*"sha256": *"([0-9a-f]{64})".*/\1/p' "$TMP/linux.json")"
SIG="$(sed -nE 's/.*"sig": *"([^"]+)".*/\1/p' "$TMP/linux.json")"
[ -n "$V" ] && [ -n "$F" ] && [ -n "$SHA" ] && [ -n "$SIG" ] || die "linux.json is not complete."
[[ "$F" =~ ^RS-WhatsApp-linux-x64-[0-9.]+\.tar\.gz$ ]] || die "Unexpected file name in linux.json."
# Rameez Scripts' signature over the version + file hash: a changed file or a fake release stops here
printf 'rswa-linux\n%s\n%s' "$V" "$SHA" > "$TMP/msg"
printf '%s' "$SIG" | base64 -d > "$TMP/sig" 2>/dev/null || die "Bad signature in linux.json."
printf '%s\n' "$PUB" > "$TMP/pub.pem"
if openssl version 2>/dev/null | grep -qE '^OpenSSL [3-9]'; then
	openssl pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/msg" -sigfile "$TMP/sig" >/dev/null 2>&1 || die "The release signature is not valid. Nothing was installed."
else
	warn "OpenSSL 3 not found: the signature is not checked, only the file's hash from GitHub."
fi
CHANGED=0; CUR=""; [ -L "$APP/current" ] && CUR="$(basename "$(readlink -f "$APP/current")")"
if [ "$CUR" = "$V" ] && [ -x "$APP/current/rs-whatsapp" ]; then
	say "Already on $V"
else
	curl -fL --progress-bar "https://github.com/$REPO/releases/download/$TAG/$F" -o "$TMP/$F" || die "Download failed."
	echo "$SHA  $TMP/$F" | sha256sum -c --quiet - || die "The download does not match its signed hash. Nothing was installed."
	mkdir -p "$APP/releases/$V.new"
	TOP="$(tar -tzf "$TMP/$F" | head -1 | cut -d/ -f1)"
	if tar -tzf "$TMP/$F" | grep -q "^$TOP/rs-whatsapp$"; then tar -xzf "$TMP/$F" -C "$APP/releases/$V.new" --strip-components=1; else tar -xzf "$TMP/$F" -C "$APP/releases/$V.new"; fi
	[ -x "$APP/releases/$V.new/rs-whatsapp" ] || die "The package has no rs-whatsapp program."
	rm -rf "$APP/releases/$V"; mv "$APP/releases/$V.new" "$APP/releases/$V"
	chown -R root:root "$APP/releases/$V"
	chmod 4755 "$APP/releases/$V/chrome-sandbox" 2>/dev/null || true   # Chromium's sandbox helper needs root + setuid
	ln -sfn "$APP/releases/$V" "$APP/current"; CHANGED=1
	ls -1dt "$APP/releases"/*/ 2>/dev/null | tail -n +3 | xargs -r rm -rf   # keep this one and the one before
	say "Installed $V"
fi

# ---------- user, data, settings ----------
id "$RUSER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin "$RUSER"
mkdir -p "$DATA"; chown -R "$RUSER:$RUSER" "$DATA"; chmod 700 "$DATA"
{
	echo "RSWA_SERVER=1"
	echo "RSWA_DATA=$DATA"
	echo "RSWA_PORT=$PORT"
	echo "RSWA_HOST=127.0.0.1"
	[ -n "$DOMAIN" ] && echo "RSWA_DOMAIN=$DOMAIN"
} > "$ENVF"
chmod 644 "$ENVF"
run_app() { runuser -u "$RUSER" -- env HOME="$DATA" RSWA_SERVER=1 RSWA_DATA="$DATA" "$APP/current/rs-whatsapp" --server --ozone-platform=headless --disable-gpu "$@"; }
if [ -n "$PASSWORD" ]; then
	systemctl stop rs-whatsapp.service 2>/dev/null || true   # one copy of the app per data folder
	printf '%s' "$PASSWORD" | run_app --set-password 2>/dev/null | grep -v "^\[" || die "Could not save the password."
	PASSWORD=""
fi

# ---------- the service + daily updates ----------
cat > /etc/systemd/system/rs-whatsapp.service <<UNIT
[Unit]
Description=RS WhatsApp server (Rameez Scripts)
After=network-online.target
Wants=network-online.target

[Service]
User=$RUSER
Group=$RUSER
EnvironmentFile=$ENVF
Environment=HOME=$DATA
WorkingDirectory=$DATA
ExecStart=$APP/current/rs-whatsapp --server --ozone-platform=headless --disable-gpu
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=25
LimitNOFILE=65536
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/rs-whatsapp-update.service <<UNIT
[Unit]
Description=RS WhatsApp update check
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -fsSL $RAW | bash -s -- --update'
UNIT
cat > /etc/systemd/system/rs-whatsapp-update.timer <<UNIT
[Unit]
Description=RS WhatsApp: check for an update once a day

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
cat > /usr/local/bin/rs-whatsapp <<'CLI'
#!/usr/bin/env bash
# RS WhatsApp server commands (Rameez Scripts)
RAW="https://raw.githubusercontent.com/rameezimdad/RS-Whatsapp-Automation/main/install.sh"
case "${1:-}" in
	update) curl -fsSL "$RAW" | sudo bash -s -- --update ;;
	password) curl -fsSL "$RAW" | sudo bash -s -- --update --password && sudo systemctl restart rs-whatsapp ;;
	domain) [ -n "${2:-}" ] || { echo "usage: rs-whatsapp domain wa.example.com"; exit 1; }; curl -fsSL "$RAW" | sudo bash -s -- --domain "$2" ;;
	status) systemctl status rs-whatsapp --no-pager; echo; ls -1 /opt/rs-whatsapp/releases 2>/dev/null | sed 's/^/installed: /' ;;
	logs) sudo journalctl -u rs-whatsapp -n 80 --no-pager; sudo tail -n 40 /var/lib/rs-whatsapp/data/logs/*.log 2>/dev/null ;;
	restart) sudo systemctl restart rs-whatsapp && echo "Restarted." ;;
	stop) sudo systemctl stop rs-whatsapp && echo "Stopped." ;;
	start) sudo systemctl start rs-whatsapp && echo "Started." ;;
	uninstall) curl -fsSL "$RAW" | sudo bash -s -- --uninstall ;;
	*) echo "rs-whatsapp  update | password | domain <name> | status | logs | restart | stop | start | uninstall" ;;
esac
CLI
chmod 755 /usr/local/bin/rs-whatsapp
systemctl daemon-reload
systemctl enable rs-whatsapp.service rs-whatsapp-update.timer >/dev/null 2>&1
if [ "$CHANGED" = 1 ] || [ "$UPDATE" = 0 ] || ! systemctl is-active --quiet rs-whatsapp.service; then systemctl restart rs-whatsapp.service; fi
systemctl start rs-whatsapp-update.timer

# ---------- HTTPS on the domain (Caddy) ----------
if [ "$CADDY" = 1 ] && [ -n "$DOMAIN" ] && [ "$UPDATE" = 0 ]; then
	if ! command -v caddy >/dev/null; then
		BUSY="$(ss -ltnp 2>/dev/null | awk '$4 ~ /:(80|443)$/ {print $NF}' | head -1)"
		[ -z "$BUSY" ] || die "Ports 80/443 are already used ($BUSY). Run again with --no-caddy and proxy $DOMAIN to 127.0.0.1:$PORT in your own web server."
		say "Installing Caddy (HTTPS)"
		apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
		curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
		curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list
		apt-get update -qq && apt-get install -y -qq caddy >/dev/null
	fi
	printf '%s {\n\tencode gzip\n\treverse_proxy 127.0.0.1:%s\n}\n' "$DOMAIN" "$PORT" > "$CADDY_SITE"
	if grep -qE '^:80[[:space:]]*\{' /etc/caddy/Caddyfile 2>/dev/null && ! grep -q rs-whatsapp.caddy /etc/caddy/Caddyfile; then
		cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-rs-whatsapp
		echo "import $CADDY_SITE" > /etc/caddy/Caddyfile   # Caddy's own sample page goes, the old file is kept next to it
	elif ! grep -q rs-whatsapp.caddy /etc/caddy/Caddyfile 2>/dev/null; then
		echo "import $CADDY_SITE" >> /etc/caddy/Caddyfile
	fi
	caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddy does not accept the settings: check /etc/caddy/Caddyfile"
	systemctl enable --now caddy >/dev/null 2>&1; systemctl reload caddy
	if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
	IP="$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
	DIP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
	if [ -n "$IP" ] && [ "$DIP" != "$IP" ]; then
		warn "$DOMAIN points at ${DIP:-nothing yet}, this server is $IP. Add an A record: $DOMAIN -> $IP. HTTPS starts by itself once it points here."
	fi
fi

# ---------- check it runs ----------
for i in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:$PORT/login" 2>/dev/null && break; sleep 1; done
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/login" 2>/dev/null || die "The app did not start. See: rs-whatsapp logs"
echo
say "RS WhatsApp $V is running."
if [ -n "$DOMAIN" ] && [ "$CADDY" = 1 ]; then echo "   Open https://$DOMAIN and sign in with your password."
elif [ -n "$DOMAIN" ]; then echo "   Point $DOMAIN (HTTPS) at http://127.0.0.1:$PORT in your web server, then open https://$DOMAIN."
else echo "   It listens on http://127.0.0.1:$PORT. Put a web server with HTTPS in front of it."; fi
echo "   Commands: rs-whatsapp update | password | status | logs | restart"
echo "   Updates come by themselves once a day."
