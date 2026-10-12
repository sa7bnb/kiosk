# Kiosk – Raspberry Pi web kiosk

Turns a Raspberry Pi 3/4/5 into a web kiosk: Chromium starts automatically in fullscreen at boot, with no mouse pointer, tabs or address bar, and shows a single web page.

The first time the device starts, it shows a simple settings page where you choose which web page to display. When you save, the device reboots and shows only the chosen page. The settings live in a separate `config.json`, so you can change them over SSH later.

## How it works

- The Raspberry Pi logs in automatically and starts Chromium in kiosk mode.
- **New device:** the screen shows a settings page with the device's IP address. You can open the same page from another computer at `http://kiosk.local:8080` (or `http://<device-IP>:8080`).
- **After you save a URL:** the address is written to `~/kiosk/config.json`, the built-in web server is turned off and the device reboots. From then on it shows only the chosen page.
- **Automatic updates** are installed daily without any action from you (see [Automatic updates](#automatic-updates)).

## Requirements

- Raspberry Pi 3/4/5
- microSD card or USB (8 GB or larger)
- Screen with HDMI
- Network via Wi-Fi or Ethernet
- Another computer for installing and administering over SSH

## Installation

### 1. Install Raspberry Pi OS

Install **Raspberry Pi OS Lite (64-bit)** on the SD card with [Raspberry Pi Imager](https://www.raspberrypi.com/software/).

In Imager, select:

1. **Raspberry Pi Device:** Raspberry Pi 4
2. **Operating System:** choose **Raspberry Pi OS (other)**, then **Raspberry Pi OS Lite (64-bit)**. The Lite version is listed under "other" and has no desktop, which is what you want here.
3. **Storage:** your microSD card or USB

Click **Edit Settings** (OS customisation) before writing the card. Configure:

| Setting | Value |
|---|---|
| Hostname | `kiosk` |
| Username and password | Your choice – remember them |
| Wi-Fi | Network name, password and country (skip if you use an Ethernet cable) |
| Time zone and keyboard layout | For example `Europe/Stockholm` and `se` |
| SSH | **Enable SSH** (password login or your public key) |

Write the card, put it in the Raspberry Pi and power it on. The first boot takes a minute or two.

> The hostname `kiosk` makes the device reachable as `kiosk.local` on your network.

### 2. Connect over SSH

From your other computer, replace `username` with the username you chose:

```bash
ssh username@kiosk.local
```

If `kiosk.local` does not resolve (older systems or networks without mDNS), use the device's IP address instead. You can find it in your router's list of connected devices.

### 3. Install git and download the script

On the Raspberry Pi:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/sa7bnb/kiosk.git
cd kiosk
```

### 4. Run the installer

```bash
sudo -v && bash install.sh && sudo reboot
```

You enter your password once (`sudo -v`). Run the script as your normal user – **not** as root and not with `sudo bash install.sh`. The script aborts in that case, because the kiosk must be set up for your user.

The script:

- Installs the required packages (Xorg, Openbox, Chromium, Python 3 and `unattended-upgrades`).
- Creates `~/kiosk/` with `server.py`, `kiosk.sh` and `config.json`.
- Creates a systemd service (`kiosk-config`) for the settings page.
- Enables automatic console login.
- Configures Chromium to start in kiosk mode at login, with the mouse pointer hidden.
- Allows the settings page to reboot the device.
- Enables automatic updates.

You can run the script again safely. An existing `config.json` is never overwritten.

## Choosing and changing the displayed page

### First time: choose a page from the settings page

After the reboot, the screen shows the settings page. Choose your page from another computer:

1. Open **`http://kiosk.local:8080`** in a browser on another computer on the same network. If the name does not resolve, use the device's IP address, for example `http://192.168.1.50:8080`. The address is also shown at the bottom of the settings page on the kiosk screen.
2. Enter the address you want to display, for example `https://example.com`. If you type only `example.com`, the page adds `http://` for you.
3. Click **Save and restart**.
4. The device saves the address in `config.json`, turns off the web server and reboots. After a minute or so, the chosen page is shown in fullscreen.

Once you have saved, the settings page is turned off, so `kiosk.local:8080` no longer responds. This is intentional.

### Later: change the page over SSH with `config.json`

Connect to the device:

```bash
ssh username@kiosk.local
```

Open the configuration file:

```bash
nano ~/kiosk/config.json
```

With a page selected, it looks like this:

```json
{
  "url": "https://example.com",
  "webserver_enabled": 0,
  "port": 8080
}
```

| Field | Description |
|---|---|
| `url` | The page to display. If empty, the settings page is shown instead. |
| `webserver_enabled` | `1` = the settings page is available, `0` = it is turned off. Set to `0` automatically when you save a URL. |
| `port` | Port for the settings page (default `8080`). |

**Option A: change the URL directly**

1. Change the value of `url` to the new page.
2. Save in nano with `Ctrl+O`, `Enter`, then exit with `Ctrl+X`.
3. Reboot with `sudo reboot`. The new page is shown after the reboot.

**Option B: bring back the settings page**

1. Change `"webserver_enabled": 0` to `"webserver_enabled": 1`.
2. Save and run `sudo reboot`.
3. After the reboot, `http://kiosk.local:8080` is available again. Choose a new page there. When you save, it is turned off again automatically.

**Good to know**

- `webserver_enabled` is `1` or `0`, with no quotes around the number.
- If `url` is empty (`""`), the settings page always starts, even if `webserver_enabled` is `0`. You cannot lock yourself out.
- The file must be valid JSON: the address goes inside quotes, and there must be no missing or extra commas. If the file is broken, the device falls back to the defaults and shows the settings page.
- You can change `port` if 8080 is already in use. It only applies to the settings page.

## Automatic updates

The installer enables `unattended-upgrades`:

- Package lists are refreshed and updates are installed automatically every day. This covers Debian updates and the Raspberry Pi repository, which includes Chromium and firmware.
- If an update requires a reboot (for example a new kernel or firmware), the device reboots itself at **04:00**. It only reboots when needed.
- Unused packages are removed, and your own configuration files are not overwritten.

A Chromium update does not trigger an automatic reboot, so the new version is used from the next reboot.

Check that it works:

```bash
sudo unattended-upgrade --dry-run -d
ls /var/log/unattended-upgrades/
```

## Troubleshooting

**`ssh: connect to host ... port 22: Connection refused`**
SSH is not enabled, or the IP address is wrong. Make sure you enabled SSH in Imager. If you have a screen and keyboard on the Pi, run `sudo systemctl enable --now ssh`.

**`kiosk.local` cannot be found**
Use the IP address instead. It is shown on the screen and in your router's device list.

**I need a command line on the Pi while the kiosk is running**
With a keyboard connected, press **Ctrl+Alt+F2** to get a login prompt. Otherwise use SSH.

**The settings page is not reachable from my computer**
Check that `webserver_enabled` is `1` in `config.json` and that your computer is on the same network. Check the service status with:

```bash
systemctl status kiosk-config
```

**The page is not shown after reboot**
Check that the address in `config.json` is correct (starts with `http://` or `https://`) and that the device has network access.

## Security

The settings page has no password and uses no encryption. Anyone on the same network can change which page is shown while it is active. It turns itself off once you have saved a URL, so use it on a network you trust.

## Files

| Path | Description |
|---|---|
| `~/kiosk/server.py` | The settings page (Python, no extra dependencies) |
| `~/kiosk/kiosk.sh` | Starts Chromium in kiosk mode |
| `~/kiosk/config.json` | Settings |
| `/etc/systemd/system/kiosk-config.service` | systemd service for the settings page |
| `~/.xinitrc`, `~/.bash_profile` | Start the display server and the kiosk at login |
| `/etc/sudoers.d/kiosk-reboot` | Allows the settings page to reboot the device |
| `/etc/apt/apt.conf.d/20auto-upgrades`, `52kiosk-unattended-upgrades` | Automatic update settings |
