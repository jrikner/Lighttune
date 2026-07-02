#!/usr/bin/env bash
# ============================================================================
# Sekonic Bridge — Raspberry Pi OS Image Builder
# ============================================================================
# Builds a ready-to-flash Raspberry Pi OS image with the Sekonic bridge
# pre-installed. Flash the resulting .img.gz to a microSD card and the Pi
# will boot straight into the bridge server.
#
# Requirements (on a Linux host):
#   sudo apt-get install kpartx qemu-user-static wget gzip
#
# Usage:
#   chmod +x build-image.sh
#   sudo ./build-image.sh [--wifi-ssid "MyNetwork" --wifi-password "secret"]
#
# Options:
#   --wifi-ssid       Pre-seed WiFi network name (optional)
#   --wifi-password   Pre-seed WiFi password (optional)
#   --hostname        Hostname for the Pi (default: sekonic-bridge)
#   --output          Output image filename (default: sekonic-bridge-pi.img.gz)
# ============================================================================

set -e

# ── defaults ──────────────────────────────────────────────────────────────────
WIFI_SSID=""
WIFI_PASS=""
PI_HOSTNAME="sekonic-bridge"
OUTPUT_IMG="sekonic-bridge-pi.img.gz"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Raspberry Pi OS Lite 64-bit (update URL/hash as new releases come out)
BASE_URL="https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-lite.img.xz"
BASE_IMG_XZ="rpi-os-lite.img.xz"
BASE_IMG="rpi-os-lite.img"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[build]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn] ${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*"; exit 1; }

# ── parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wifi-ssid)     WIFI_SSID="$2";     shift 2 ;;
        --wifi-password) WIFI_PASS="$2";     shift 2 ;;
        --hostname)      PI_HOSTNAME="$2";   shift 2 ;;
        --output)        OUTPUT_IMG="$2";    shift 2 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || error "Must be run as root (use sudo)"

# ── 1. Download base image ────────────────────────────────────────────────────
if [ ! -f "$BASE_IMG" ]; then
    if [ ! -f "$BASE_IMG_XZ" ]; then
        info "Downloading Raspberry Pi OS Lite 64-bit…"
        wget -q --show-progress -O "$BASE_IMG_XZ" "$BASE_URL"
    fi
    info "Extracting image…"
    xz -d "$BASE_IMG_XZ"
fi

# Work on a copy so the original is preserved
info "Creating working copy…"
cp "$BASE_IMG" work.img

# ── 2. Mount the image ────────────────────────────────────────────────────────
info "Mounting image partitions…"
LOOP=$(losetup -f --show --partscan work.img)
sleep 1

BOOT_PART="${LOOP}p1"
ROOT_PART="${LOOP}p2"
BOOT_MNT="$(mktemp -d)"
ROOT_MNT="$(mktemp -d)"

mount "$BOOT_PART" "$BOOT_MNT"
mount "$ROOT_PART" "$ROOT_MNT"

cleanup() {
    set +e
    umount "$BOOT_MNT" 2>/dev/null
    umount "$ROOT_MNT" 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
    rm -rf "$BOOT_MNT" "$ROOT_MNT"
}
trap cleanup EXIT

# ── 3. Enable SSH ─────────────────────────────────────────────────────────────
info "Enabling SSH…"
touch "$BOOT_MNT/ssh"

# ── 4. Set hostname ───────────────────────────────────────────────────────────
info "Setting hostname to: $PI_HOSTNAME"
echo "$PI_HOSTNAME" > "$ROOT_MNT/etc/hostname"
sed -i "s/raspberrypi/$PI_HOSTNAME/g" "$ROOT_MNT/etc/hosts" 2>/dev/null || true

# ── 5. WiFi credentials ───────────────────────────────────────────────────────
if [ -n "$WIFI_SSID" ]; then
    info "Pre-seeding WiFi: $WIFI_SSID"
    cat > "$BOOT_MNT/wpa_supplicant.conf" << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PASS"
    key_mgmt=WPA-PSK
}
WPAEOF
else
    warn "No WiFi credentials provided. Configure WiFi via Raspberry Pi Imager"
    warn "or edit /boot/wpa_supplicant.conf on the SD card before first boot."
fi

# ── 6. Copy bridge files to the image ────────────────────────────────────────
info "Copying bridge server files…"
BRIDGE_DEST="$ROOT_MNT/opt/sekonic-bridge"
mkdir -p "$BRIDGE_DEST"
cp "$SCRIPT_DIR/server.py"           "$BRIDGE_DEST/"
cp "$SCRIPT_DIR/meter_c7000_bulk.py"  "$BRIDGE_DEST/"
cp "$SCRIPT_DIR/meter_mock.py"       "$BRIDGE_DEST/"
cp "$SCRIPT_DIR/requirements.txt"    "$BRIDGE_DEST/"
cp "$SCRIPT_DIR/setup-pi.sh"         "$BRIDGE_DEST/"
cp "$SCRIPT_DIR/sekonic-bridge.service" "$ROOT_MNT/etc/systemd/system/"
chmod +x "$BRIDGE_DEST/setup-pi.sh"

# ── 7. firstrun script (runs on first boot) ───────────────────────────────────
info "Installing firstrun hook…"
cat > "$BOOT_MNT/firstrun.sh" << 'FIRSTRUN'
#!/bin/bash
# First-boot setup — installs Python deps and starts the bridge service
set -e
cd /opt/sekonic-bridge

apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv python3-usb libusb-1.0-0

# Create service user
if ! id sekonic &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin sekonic
fi

# Virtualenv + deps
python3 -m venv /opt/sekonic-bridge/venv
/opt/sekonic-bridge/venv/bin/pip install --quiet -r /opt/sekonic-bridge/requirements.txt
/opt/sekonic-bridge/venv/bin/pip install --quiet pyusb

# USB udev rule
cat > /etc/udev/rules.d/99-sekonic-c7000.rules << 'UDEV'
SUBSYSTEM=="usb", MODE="0664", GROUP="sekonic"
UDEV
udevadm control --reload-rules

# Set ownership
chown -R sekonic:sekonic /opt/sekonic-bridge

# Enable and start systemd service
systemctl daemon-reload
systemctl enable sekonic-bridge
systemctl start sekonic-bridge

# Remove this firstrun script so it only runs once
rm -f /boot/firstrun.sh
sed -i 's| systemd.run.*||g' /boot/cmdline.txt
FIRSTRUN
chmod +x "$BOOT_MNT/firstrun.sh"

# Add firstrun hook to cmdline.txt
CMDLINE="$BOOT_MNT/cmdline.txt"
if [ -f "$CMDLINE" ] && ! grep -q "firstrun" "$CMDLINE"; then
    sed -i "s|$| systemd.run=/boot/firstrun.sh systemd.run_success_action=reboot|" "$CMDLINE"
fi

# ── 8. Unmount and compress ───────────────────────────────────────────────────
info "Unmounting image…"
umount "$BOOT_MNT"
umount "$ROOT_MNT"
losetup -d "$LOOP"
trap - EXIT
rm -rf "$BOOT_MNT" "$ROOT_MNT"

info "Compressing image → $OUTPUT_IMG"
gzip -9 -c work.img > "$OUTPUT_IMG"
rm work.img

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "=== Image built successfully ==="
info ""
info "File:  $OUTPUT_IMG  ($(du -sh "$OUTPUT_IMG" | cut -f1))"
info ""
info "Flash to SD card:"
info "  1. Download Raspberry Pi Imager: https://www.raspberrypi.com/software/"
info "  2. Choose 'Use custom image' → select $OUTPUT_IMG"
info "  3. Flash, insert SD card, power on Pi"
info "  4. Wait ~3 minutes for first-boot setup to complete"
info "  5. Find Pi IP: nmap -sn 192.168.x.0/24 | grep sekonic"
info "  6. Test: curl http://<pi-ip>:8765/status"
