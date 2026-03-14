# Sekonic Bridge — Remote Measurement Server

Lighttune add-on that connects a **Sekonic C-7000 Spectromaster** to the show network so the GrandMA3 console can trigger measurements and read values automatically — without the operator leaving FOH.

---

## How It Works

```
[Sekonic C-7000]
      │ USB cable
      ▼
[Raspberry Pi Zero 2W]  ──── WiFi / Ethernet ────►  [GrandMA3 Console @ FOH]
  Python HTTP server                                    SekonicCalibrator plugin
  port 8765                                             calls /measure via socket.http
                                                               │
                                                     [iPhone / Tablet]
                                                     Operator uses GrandMA3
                                                     WebRemote in Safari
```

The Raspberry Pi sits on stage near the meter. The GrandMA3 plugin sends a POST request to trigger a measurement and receives CCT, Duv, CRI, R9, and TLCI back as JSON — automatically filling in the calibration dialogs.

> **iPhone note:** The iPhone cannot directly interface with the C-7000 (iOS has strict USB restrictions). Instead, use the iPhone as a GrandMA3 WebRemote client — open `http://<console-ip>/` in Safari and control the entire calibration session remotely.

---

## What to Buy

### Required hardware (~€44 total)

| Item | Where to buy | Price |
|------|-------------|-------|
| **Raspberry Pi Zero 2W** | [rpilocator.com](https://rpilocator.com/) (tracks stock globally) | ~€18 |
| **MicroSD card — 8 GB+, Class 10** | Amazon, local electronics store | ~€8 |
| **USB Micro-B OTG adapter** (Micro-B female to USB-A female) | Amazon — search "Micro USB OTG adapter" | ~€3 |
| **USB Mini-B to USB-A cable, 1–2 m** | Amazon — "USB A to Mini B cable" | ~€5 |
| **USB power supply — 5 V / 2.5 A, Micro-B plug** | Amazon — "Raspberry Pi Zero power supply" | ~€10 |

### Recommended extras

| Item | Use | Price |
|------|-----|-------|
| **Raspberry Pi Zero case** | Protects the Pi; some have mounting holes | ~€5 |
| **USB 2.0 active extension cable, 5–10 m** | Reach fixtures further from the Pi | ~€15 |
| **Icron USB Ranger 2204** | USB over Cat5e up to 100 m — ideal for large venues | ~€150 |

> **USB cable length:** Standard USB 2.0 passive cables max out at 5 m. Use a powered active extension cable for longer runs. The Icron Ranger extends USB over standard Ethernet cable for true long-throw installations.

---

## Setup — Option 1: Pre-Built Image (Recommended)

The easiest path. Build a ready-to-flash image on any Linux machine, then flash it to the SD card.

### Step 1 — Build the image

```bash
git clone https://github.com/jrikner/Lighttune-0.1
cd Lighttune-0.1/sekonic-bridge

# Without WiFi pre-seed (configure via Raspberry Pi Imager):
sudo ./build-image.sh

# With WiFi pre-seeded:
sudo ./build-image.sh --wifi-ssid "ShowNetwork" --wifi-password "yourpassword"
```

This downloads Raspberry Pi OS Lite, injects the bridge files, and outputs `sekonic-bridge-pi.img.gz`.

### Step 2 — Flash to SD card

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Click **"Choose OS"** → **"Use custom image"** → select `sekonic-bridge-pi.img.gz`
3. Click **"Choose Storage"** → select your microSD card
4. Click the **gear icon** (⚙️) to open advanced options:
   - Set **hostname**: `sekonic-bridge`
   - Enable **SSH** (set a password or add your public key)
   - Set **WiFi credentials** if not pre-seeded in the build step
5. Click **"Write"**

### Step 3 — First boot

Insert the SD card into the Pi, connect power. The Pi will:
1. Boot Raspberry Pi OS (30–60 seconds)
2. Run first-time setup: install Python packages, create service user, configure USB permissions (~3 minutes, requires internet)
3. Start the bridge server automatically
4. Reboot once

**Total first-boot time: ~5 minutes.**

---

## Setup — Option 2: Run Setup Script on Existing Pi

If you already have a Raspberry Pi running, skip the image build:

```bash
curl -fsSL https://raw.githubusercontent.com/jrikner/Lighttune-0.1/main/sekonic-bridge/setup-pi.sh | sudo bash
```

Or download and run manually:

```bash
wget https://raw.githubusercontent.com/jrikner/Lighttune-0.1/main/sekonic-bridge/setup-pi.sh
sudo bash setup-pi.sh
```

---

## Finding the Pi's IP Address

After the Pi boots, find its IP using one of:

```bash
# Option 1: nmap scan (replace with your network range)
nmap -sn 192.168.1.0/24 | grep -A1 "sekonic-bridge"

# Option 2: from your router's admin page (look for "sekonic-bridge")

# Option 3: arp
arp -a | grep sekonic

# Option 4: SSH directly if you know it's there
ssh pi@sekonic-bridge.local
```

> Set a **static IP** on the Pi (or reserve one via DHCP) so the address never changes between show days.

---

## Configuring GrandMA3

Add the bridge IP to `config.json` in the SekonicCalibrator data folder:

**Windows path:**
```
%APPDATA%\MALightingTechnology\gma3_library\datapools\plugins\SekonicCalibrator\data\config.json
```

**Linux/macOS path:**
```
~/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/data/config.json
```

Example `config.json`:
```json
{
  "github_token":    "ghp_...",
  "github_username": "your_username",
  "community_upload": false,
  "bridge_ip":       "192.168.1.50",
  "bridge_port":     8765
}
```

> `bridge_ip` and `bridge_port` are the only fields needed to enable remote measurement. The GitHub fields are optional.

---

## Testing the Connection

Run these from the **Pi terminal** (or any computer on the same network via SSH or shell) — not from the GrandMA3 console:

```bash
# Check bridge status
curl http://<pi-ip>:8765/status

# Auto-discover VID/PID (C-7000 must be connected to the Pi)
curl http://<pi-ip>:8765/discover

# Capture measurement protocol (press meter button within 30 s)
curl -X POST http://<pi-ip>:8765/capture

# Auto-discover remote trigger (takes up to ~2 min)
curl -X POST http://<pi-ip>:8765/learn_trigger

# Trigger a test measurement
curl -X POST http://<pi-ip>:8765/measure
```

Expected status response:
```json
{
  "status": "ok",
  "meter": "C-7000",
  "connected": true,
  "uptime_s": 3600,
  "last_error": null,
  "version": "1.0.0",
  "device_configured": true,
  "protocol_captured": true,
  "trigger_discovered": true
}
```

Expected measurement response:
```json
{
  "cct": 5612,
  "duv": 0.0028,
  "cri": 94,
  "r9": 87,
  "tlci": 91,
  "timestamp": "2026-03-13T21:45:00Z"
}
```

From the console, use the **"Bridge Status"** option in the main menu to verify connectivity before starting a calibration session.

---

## Using from iPhone (WebRemote)

1. Connect iPhone to the same WiFi network as the GrandMA3 console
2. Open **Safari** → navigate to `http://<grandma3-console-ip>/`
3. The GrandMA3 WebRemote loads — all plugin dialogs appear here
4. Run calibration normally — the measurement dialog will offer **"Remote Measurement"** when the bridge is configured

The calibration session pauses for ~2–5 seconds while the bridge triggers the C-7000 and receives the result. All values are filled in automatically.

---

## USB Protocol Note

The C-7000 USB HID protocol is not publicly documented. The bridge includes a **3-step self-configuration wizard** — no Wireshark required.

### Auto-discovery wizard (recommended — no Wireshark)

Run the wizard from the GrandMA3 plugin: **Bridge Status → Run Setup**. Three steps:

| Step | What happens | Your action |
|------|-------------|-------------|
| **1 – Discover** | Bridge scans USB, finds Sekonic VID/PID | Make sure C-7000 is plugged into the Pi |
| **2 – Capture** | Bridge listens for one measurement response | **Press MEASURE** on the C-7000 |
| **3 – Remote Trigger** | Bridge probes HID commands to find the trigger byte | Click "Discover" and wait ~1–2 min |

After step 3 succeeds, the bridge is **fully hands-free** — `POST /measure` triggers the meter automatically. All results are saved in `device_config.json`.

Or run each step manually from the Pi terminal:

```bash
# Step 1 — discover VID/PID
curl http://localhost:8765/discover

# Step 2 — press MEASURE on the meter first, then:
curl -X POST http://localhost:8765/capture

# Step 3 — auto-probe the remote trigger (takes up to 2 min)
curl -X POST http://localhost:8765/learn_trigger
```

Or use the standalone discovery script on the Pi to get VID/PID:

```bash
python3 discover_device.py
```

> **Step 3 explained:** Because the Pi is the USB host, it has full control over
> what it sends to the C-7000. `POST /learn_trigger` tries a prioritised list of
> short HID byte sequences and checks whether the meter responds with valid
> measurement data. The first sequence that elicits a plausible response is
> saved as the trigger command. No Wireshark or second computer needed.

### Fallback — Manual Wireshark capture (advanced)

If `POST /learn_trigger` cannot find the trigger (e.g. the meter uses an
unusual padding requirement), you can capture it manually:

| Platform | Tool | Notes |
|----------|------|-------|
| **Windows (recommended)** | Wireshark + USBPcap | Easiest; no OS changes needed; USBPcap is bundled with Wireshark |
| **Linux / Raspberry Pi** | Wireshark + usbmon | `sudo modprobe usbmon`, then capture the `usbmon` interface in Wireshark |
| **macOS** | Not recommended | Requires disabling System Integrity Protection (SIP) |

**Windows capture steps:**
1. Install [Wireshark](https://www.wireshark.org/) (includes USBPcap)
2. Connect the C-7000 via USB to the Windows PC
3. Open Wireshark → select the USBPcap interface showing the C-7000
4. Open the Sekonic C-700/7000 Utility Software and click **"Measure"**
5. Filter: `usb.transfer_type == 3` (interrupt = HID packets)
6. Find the **OUT packet** — bytes sent host → device to trigger a measurement
7. Update `meter_c7000_hid.py`: set `TRIGGER_CMD` to those bytes and restart the bridge

---

## Troubleshooting

### Bridge service not starting
```bash
journalctl -u sekonic-bridge -n 50 --no-pager
```

### Meter not detected
```bash
# Check if C-7000 is visible as a USB device
lsusb | grep -i sekonic

# If not found, try a different USB cable or port
# Check dmesg for USB errors
dmesg | tail -20
```

### Can't connect from GrandMA3
```bash
# On the Pi, check the bridge is listening
ss -tlnp | grep 8765

# Test locally on the Pi
curl http://localhost:8765/status

# Check firewall (Pi OS Lite has none by default; check show network firewall)
```

### Wrong IP address
```bash
# On the Pi
hostname -I

# Set a static IP — edit /etc/dhcpcd.conf:
sudo nano /etc/dhcpcd.conf
# Add at the bottom:
# interface wlan0
# static ip_address=192.168.1.50/24
# static routers=192.168.1.1
# static domain_name_servers=192.168.1.1
```

### Service management
```bash
sudo systemctl status  sekonic-bridge   # check status
sudo systemctl restart sekonic-bridge   # restart
sudo systemctl stop    sekonic-bridge   # stop
sudo journalctl -u sekonic-bridge -f    # live log
```

---

## Running in Mock Mode (development/testing)

Test the full Lua plugin integration without any hardware:

```bash
# On any machine with Python 3
cd sekonic-bridge
pip install -r requirements.txt
python3 server.py --mock
```

The mock server returns realistic randomised values and responds as if a real meter is connected. Set `bridge_ip` in config.json to your development machine's IP.

---

## Architecture Notes

- The bridge server runs as a `systemd` service under a dedicated unprivileged `sekonic` user
- USB access is granted via a udev rule — no `sudo` required at runtime
- The `/measure` endpoint blocks until the meter responds (up to 35 s) — this is intentional; it keeps the Lua plugin simple (one `socket.http` call)
- Concurrent measurement requests are rejected with HTTP 409 to prevent race conditions
- All measurements are logged to `bridge.log` in the install directory
