#!/bin/bash
# All-in-one installer for a Chromium kiosk on Raspberry Pi OS Lite (64-bit).
# Usage:  bash install.sh      (as a normal user, not root)
# Creates server.py, kiosk.sh and config.json, installs packages and
# configures autologin, kiosk startup and the configuration server.
set -e

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as a normal user, not as root (the script uses sudo itself)."
  exit 1
fi

USER_NAME="$(id -un)"
HOME_DIR="$HOME"
DEST="$HOME_DIR/kiosk"

echo "==> Installing packages"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  xserver-xorg xinit x11-xserver-utils openbox python3 unattended-upgrades
sudo apt-get install -y chromium || sudo apt-get install -y chromium-browser

mkdir -p "$DEST"

echo "==> Creating $DEST/server.py"
cat > "$DEST/server.py" <<'KIOSK_SERVER_EOF'
#!/usr/bin/env python3
"""Simple configuration web page for the Chromium kiosk.

Started by systemd (kiosk-config.service). Exits immediately if
webserver_enabled = 0 in config.json and a URL has already been saved.
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
DEFAULTS = {"url": "", "webserver_enabled": 1, "port": 8080, "rotation": 0}
ROTATIONS = [
    (0, "0° (normal)"),
    (90, "90° (clockwise)"),
    (180, "180° (upside down)"),
    (270, "270° (counter-clockwise)"),
]


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


def get_rotation(cfg):
    try:
        return int(cfg.get("rotation", 0)) % 360
    except (TypeError, ValueError):
        return 0


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
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kiosk settings</title>
<style>
 body{{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:0;display:flex;
      min-height:100vh;align-items:center;justify-content:center}}
 .card{{background:#1e1e1e;padding:2rem 2.5rem;border-radius:12px;width:min(560px,90vw)}}
 h1{{margin-top:0;font-size:1.5rem}}
 input[type=text]{{width:100%;box-sizing:border-box;padding:.8rem;font-size:1.1rem;border-radius:6px;
      border:1px solid #555;background:#111;color:#fff}}
 label{{display:block;margin-top:1rem;margin-bottom:.3rem}}
 select{{width:100%;box-sizing:border-box;padding:.8rem;font-size:1.1rem;border-radius:6px;
      border:1px solid #555;background:#111;color:#fff}}
 button{{margin-top:1rem;padding:.8rem 1.6rem;font-size:1.1rem;border:0;border-radius:6px;
      background:#2f7de1;color:#fff;cursor:pointer}}
 .muted{{color:#999;font-size:.9rem}} .err{{color:#ff7b7b}} .ok{{color:#7bff9b}}
</style></head><body><div class="card">
<h1>Choose page to display</h1>
{message}
<form method="post" action="/save">
 <label for="url">Web page address</label>
 <input type="text" id="url" name="url" value="{url}" placeholder="e.g. https://example.com" autofocus>
 <label for="rotation">Screen rotation</label>
 <select id="rotation" name="rotation">{rotation_options}</select>
 <button type="submit">Save and restart</button>
</form>
<p class="muted">The device will reboot and then show only the chosen page.
The configuration server is turned off. Re-enable it by setting
<code>webserver_enabled</code> to 1 in config.json.</p>
<p class="muted">Reach this page from another computer: {addrs}</p>
</div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, body, code=200):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _page(self, message="", url=None, rotation=None, code=200):
        cfg = load()
        port = cfg["port"]
        addrs = ", ".join(f"http://{ip}:{port}" for ip in local_ips()) or "(no IP address found)"
        selected = get_rotation(cfg) if rotation is None else rotation
        options = "".join(
            f'<option value="{value}"{" selected" if value == selected else ""}>{label}</option>'
            for value, label in ROTATIONS
        )
        self._send(PAGE.format(
            message=message,
            url=html.escape(cfg["url"] if url is None else url, quote=True),
            rotation_options=options,
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
        try:
            rotation = int(form.get("rotation", ["0"])[0]) % 360
        except ValueError:
            rotation = 0
        if rotation not in (0, 90, 180, 270):
            rotation = 0
        url = normalize_url(raw)
        if not url:
            return self._page('<p class="err">Invalid address. Enter an http(s) address.</p>',
                              url=raw, rotation=rotation, code=400)
        cfg = load()
        cfg["url"] = url
        cfg["rotation"] = rotation
        cfg["webserver_enabled"] = 0
        save(cfg)
        self._send('<!doctype html><meta charset="utf-8"><body style="font-family:sans-serif;'
                   'background:#111;color:#7bff9b;text-align:center;padding-top:20vh">'
                   '<h1>Saved! Restarting…</h1></body>')
        reboot_later()

    def log_message(self, *args):
        pass


def main():
    cfg = load()
    if not int(cfg["webserver_enabled"]) and cfg["url"]:
        print("Web server disabled in config.json – exiting.")
        return 0
    server = ThreadingHTTPServer(("0.0.0.0", int(cfg["port"])), Handler)
    print(f"Configuration server on port {cfg['port']}")
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
KIOSK_SERVER_EOF

echo "==> Creating $DEST/kiosk.sh"
cat > "$DEST/kiosk.sh" <<'KIOSK_SH_EOF'
#!/bin/bash
# Starts Chromium in kiosk mode. Run from ~/.xinitrc.
BASE="$(cd "$(dirname "$0")" && pwd)"

# Disable screen blanking / power saving
xset s off
xset -dpms
xset s noblank

# Rotate the screen according to "rotation" in config.json (0, 90, 180 or 270)
ROTATION="$(python3 -c 'import json, sys
try:
    print(int(json.load(open(sys.argv[1])).get("rotation", 0)) % 360)
except Exception:
    print(0)' "$BASE/config.json")"
case "$ROTATION" in
  90)  XR_ROTATE=right ;;
  180) XR_ROTATE=inverted ;;
  270) XR_ROTATE=left ;;
  *)   XR_ROTATE=normal ;;
esac
if [ "$XR_ROTATE" != "normal" ]; then
  XR_OUTPUT="$(xrandr 2>/dev/null | awk '/ connected/ {print $1; exit}')"
  [ -n "$XR_OUTPUT" ] && xrandr --output "$XR_OUTPUT" --rotate "$XR_ROTATE"
fi

# Read config.json, pick the target URL and wait for network/server
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
    # New device: show the local settings page, wait until the server responds
    for _ in range(60):
        try:
            socket.create_connection(("127.0.0.1", port), 1).close()
            break
        except OSError:
            time.sleep(1)
    print(f"http://localhost:{port}")
else:
    host = urlparse(url if "://" in url else "http://" + url).hostname
    for _ in range(60):  # wait up to 60 s for DNS/network
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
  # Avoid the "Chromium didn't shut down correctly" bar after a power loss
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

  sleep 2   # restart Chromium if it crashes
done
KIOSK_SH_EOF

echo "==> Creating $DEST/config.json (if it doesn't already exist)"
if [ ! -f "$DEST/config.json" ]; then
  cat > "$DEST/config.json" <<'KIOSK_CFG_EOF'
{
  "url": "",
  "webserver_enabled": 1,
  "port": 8080,
  "rotation": 0
}
KIOSK_CFG_EOF
fi

# Add any setting missing from an existing config.json (existing values are kept)
python3 - "$DEST/config.json" <<'KIOSK_MERGE_EOF'
import json, sys

path = sys.argv[1]
defaults = {"url": "", "webserver_enabled": 1, "port": 8080, "rotation": 0}
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)  # leave an unreadable file untouched
missing = {k: v for k, v in defaults.items() if k not in cfg}
if missing:
    cfg.update(missing)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
KIOSK_MERGE_EOF

chmod +x "$DEST/server.py" "$DEST/kiosk.sh"

echo "==> Allowing the configuration server to reboot without a password"
echo "$USER_NAME ALL=(root) NOPASSWD: /usr/sbin/reboot" | sudo tee /etc/sudoers.d/kiosk-reboot >/dev/null
sudo chmod 440 /etc/sudoers.d/kiosk-reboot

echo "==> Creating systemd service for the configuration server"
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

echo "==> Enabling automatic console login"
sudo raspi-config nonint do_boot_behaviour B2

echo "==> Creating ~/.xinitrc and startx at login on tty1"
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

echo "==> Enabling automatic updates (unattended-upgrades)"
# Enable daily package list updates and automatic upgrades
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Custom settings file: include all Debian and Raspberry Pi updates
# (not just security), keep existing config files and reboot at night
# when needed. Automatic-Reboot-WithUsers is required because the kiosk user is logged in.
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
echo "Done! Reboot with:  sudo reboot"
echo "After the reboot the settings page is shown on the screen, and you can"
echo "reach it from another computer at http://<device-IP>:8080"
