#!/bin/bash
# Allt-i-ett-installation av Chromium-kiosk på Raspberry Pi OS Lite (64-bit).
# Använd:  bash install.sh      (som vanlig användare, inte root)
# Skapar server.py, kiosk.sh och config.json, installerar paket och
# konfigurerar autologin, kiosk-start och konfigurationsservern.
set -e

if [ "$(id -u)" -eq 0 ]; then
  echo "Kör som vanlig användare, inte som root (scriptet använder sudo själv)."
  exit 1
fi

USER_NAME="$(id -un)"
HOME_DIR="$HOME"
DEST="$HOME_DIR/kiosk"

echo "==> Installerar paket"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  xserver-xorg xinit x11-xserver-utils openbox python3 unattended-upgrades
sudo apt-get install -y chromium || sudo apt-get install -y chromium-browser

mkdir -p "$DEST"

echo "==> Skapar $DEST/server.py"
cat > "$DEST/server.py" <<'KIOSK_SERVER_EOF'
#!/usr/bin/env python3
"""Enkel konfigurationswebb för Chromium-kiosken.

Startas av systemd (kiosk-config.service). Avslutar direkt om
webserver_enabled = 0 i config.json och en URL redan är sparad.
"""
import html
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(BASE, "config.json")
DEFAULTS = {"url": "", "webserver_enabled": 1, "port": 8080}


def load():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return cfg


def save(cfg):
    tmp = CONFIG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, CONFIG)


def normalize_url(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    if "://" not in raw:
        raw = "http://" + raw
    p = urlparse(raw)
    if p.scheme not in ("http", "https") or not p.netloc:
        return None
    return raw


def local_ips():
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3).stdout
        return out.split()
    except Exception:
        return []


def reboot_later():
    def _go():
        time.sleep(2)
        subprocess.run(["sudo", "/usr/sbin/reboot"])
    threading.Thread(target=_go, daemon=True).start()


PAGE = """<!doctype html>
<html lang="sv"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kiosk-inställningar</title>
<style>
 body{{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:0;display:flex;
      min-height:100vh;align-items:center;justify-content:center}}
 .card{{background:#1e1e1e;padding:2rem 2.5rem;border-radius:12px;width:min(560px,90vw)}}
 h1{{margin-top:0;font-size:1.5rem}}
 input[type=text]{{width:100%;box-sizing:border-box;padding:.8rem;font-size:1.1rem;border-radius:6px;
      border:1px solid #555;background:#111;color:#fff}}
 button{{margin-top:1rem;padding:.8rem 1.6rem;font-size:1.1rem;border:0;border-radius:6px;
      background:#2f7de1;color:#fff;cursor:pointer}}
 .muted{{color:#999;font-size:.9rem}} .err{{color:#ff7b7b}} .ok{{color:#7bff9b}}
</style></head><body><div class="card">
<h1>Välj sida att visa</h1>
{message}
<form method="post" action="/save">
 <input type="text" name="url" value="{url}" placeholder="t.ex. https://example.com" autofocus>
 <button type="submit">Spara och starta om</button>
</form>
<p class="muted">Enheten startar om och visar därefter bara den valda sidan.
Konfigurationsservern stängs av. Aktivera den igen genom att sätta
<code>webserver_enabled</code> till 1 i config.json.</p>
<p class="muted">Nå den här sidan från annan dator: {addrs}</p>
</div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, body, code=200):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _page(self, message="", url=None, code=200):
        cfg = load()
        port = cfg["port"]
        addrs = ", ".join(f"http://{ip}:{port}" for ip in local_ips()) or "(ingen IP hittades)"
        self._send(PAGE.format(
            message=message,
            url=html.escape(cfg["url"] if url is None else url, quote=True),
            addrs=html.escape(addrs),
        ), code)

    def do_GET(self):
        self._page()

    def do_POST(self):
        if self.path != "/save":
            return self._send("Not found", 404)
        length = int(self.headers.get("Content-Length", 0) or 0)
        form = parse_qs(self.rfile.read(min(length, 8192)).decode("utf-8", "replace"))
        raw = form.get("url", [""])[0]
        url = normalize_url(raw)
        if not url:
            return self._page('<p class="err">Ogiltig adress. Ange en http(s)-adress.</p>', url=raw, code=400)
        cfg = load()
        cfg["url"] = url
        cfg["webserver_enabled"] = 0
        save(cfg)
        self._send('<!doctype html><meta charset="utf-8"><body style="font-family:sans-serif;'
                   'background:#111;color:#7bff9b;text-align:center;padding-top:20vh">'
                   '<h1>Sparat! Startar om…</h1></body>')
        reboot_later()

    def log_message(self, *args):
        pass


def main():
    cfg = load()
    if not int(cfg["webserver_enabled"]) and cfg["url"]:
        print("Webserver avstängd i config.json – avslutar.")
        return 0
    server = ThreadingHTTPServer(("0.0.0.0", int(cfg["port"])), Handler)
    print(f"Konfigurationsserver på port {cfg['port']}")
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
KIOSK_SERVER_EOF

echo "==> Skapar $DEST/kiosk.sh"
cat > "$DEST/kiosk.sh" <<'KIOSK_SH_EOF'
#!/bin/bash
# Startar Chromium i kioskläge. Körs från ~/.xinitrc.
BASE="$(cd "$(dirname "$0")" && pwd)"

# Stäng av skärmsläckare / strömsparläge
xset s off
xset -dpms
xset s noblank

# Läs config.json, välj mål-URL och vänta på nätverk/server
TARGET="$(python3 - "$BASE/config.json" <<'EOF'
import json, socket, sys, time
from urllib.parse import urlparse

try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    cfg = {}
url = (cfg.get("url") or "").strip()
port = int(cfg.get("port", 8080))

if not url:
    # Ny enhet: visa den lokala inställningssidan, vänta tills servern svarar
    for _ in range(60):
        try:
            socket.create_connection(("127.0.0.1", port), 1).close()
            break
        except OSError:
            time.sleep(1)
    print(f"http://localhost:{port}")
else:
    host = urlparse(url if "://" in url else "http://" + url).hostname
    for _ in range(60):  # vänta upp till 60 s på DNS/nätverk
        try:
            socket.getaddrinfo(host, None)
            break
        except OSError:
            time.sleep(1)
    print(url)
EOF
)"

CHROMIUM="$(command -v chromium || command -v chromium-browser)"

while true; do
  # Undvik "Chromium stängdes ned felaktigt"-ruta efter strömavbrott
  PREFS="$HOME/.config/chromium/Default/Preferences"
  if [ -f "$PREFS" ]; then
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"Crashed"/"exit_type":"Normal"/' "$PREFS"
  fi

  "$CHROMIUM" \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-translate \
    --no-first-run \
    --password-store=basic \
    --check-for-update-interval=31536000 \
    --overscroll-history-navigation=0 \
    --autoplay-policy=no-user-gesture-required \
    "$TARGET"

  sleep 2   # starta om Chromium om den kraschar
done
KIOSK_SH_EOF

echo "==> Skapar $DEST/config.json (om den inte redan finns)"
if [ ! -f "$DEST/config.json" ]; then
  cat > "$DEST/config.json" <<'KIOSK_CFG_EOF'
{
  "url": "",
  "webserver_enabled": 1,
  "port": 8080
}
KIOSK_CFG_EOF
fi

chmod +x "$DEST/server.py" "$DEST/kiosk.sh"

echo "==> Tillåter omstart utan lösenord för konfigurationsservern"
echo "$USER_NAME ALL=(root) NOPASSWD: /usr/sbin/reboot" | sudo tee /etc/sudoers.d/kiosk-reboot >/dev/null
sudo chmod 440 /etc/sudoers.d/kiosk-reboot

echo "==> Skapar systemd-tjänst för konfigurationsservern"
sudo tee /etc/systemd/system/kiosk-config.service >/dev/null <<EOF
[Unit]
Description=Kiosk config web server
After=network.target

[Service]
User=$USER_NAME
WorkingDirectory=$DEST
ExecStart=/usr/bin/python3 $DEST/server.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable kiosk-config.service

echo "==> Aktiverar automatisk konsolinloggning"
sudo raspi-config nonint do_boot_behaviour B2

echo "==> Skapar ~/.xinitrc och startx vid inloggning på tty1"
cat > "$HOME_DIR/.xinitrc" <<EOF
#!/bin/sh
openbox &
exec $DEST/kiosk.sh
EOF
chmod +x "$HOME_DIR/.xinitrc"

touch "$HOME_DIR/.bash_profile"
if ! grep -q "# kiosk-autostart" "$HOME_DIR/.bash_profile"; then
  cat >> "$HOME_DIR/.bash_profile" <<'EOF'

# kiosk-autostart
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx -- -nocursor
fi
EOF
fi

echo "==> Aktiverar automatiska uppdateringar (unattended-upgrades)"
# Slå på dagliga paketlistor och automatisk uppgradering
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Egen inställningsfil: inkludera alla Debian- och Raspberry Pi-uppdateringar
# (inte bara säkerhet), behåll befintliga config-filer och starta om natten
# vid behov. Automatic-Reboot-WithUsers krävs eftersom kiosken är inloggad.
sudo tee /etc/apt/apt.conf.d/52kiosk-unattended-upgrades >/dev/null <<'EOF'
Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=${distro_codename}-updates";
Unattended-Upgrade::Origins-Pattern:: "origin=Raspberry Pi Foundation,codename=${distro_codename}";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
};
EOF
sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

echo
echo "Klart! Starta om med:  sudo reboot"
echo "Efter omstart visas inställningssidan på skärmen, och du når den"
echo "från en annan dator på http://<enhetens-IP>:8080"
