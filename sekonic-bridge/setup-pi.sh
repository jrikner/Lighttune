#!/usr/bin/env bash
# ============================================================================
# Sekonic Bridge — Raspberry Pi Setup Script
# ============================================================================
# Run this ONCE on a fresh Raspberry Pi OS Lite (64-bit) installation.
# It installs all dependencies, copies the bridge files, creates a systemd
# service that starts automatically on boot, and sets up USB permissions.
#
# Usage (run as root or with sudo):
#   sudo bash setup-pi.sh
#
# One-line install from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/jrikner/Lighttune-0.1/main/sekonic-bridge/setup-pi.sh | sudo bash
# ============================================================================

set -e

REPO_URL="https://raw.githubusercontent.com/jrikner/Lighttune-0.1/main/sekonic-bridge"
INSTALL_DIR="/opt/sekonic-bridge"
SERVICE_USER="sekonic"
SERVICE_FILE="/etc/systemd/system/sekonic-bridge.service"
UDEV_FILE="/etc/udev/rules.d/99-sekonic-c7000.rules"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

info()    { echo -e "${GREEN}[setup]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn] ${NC} $*"; }
error()   { echo -e "${RED}[error]${NC} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || error "This script must be run as root (use sudo)"

info "=== Sekonic Bridge Setup for Raspberry Pi ==="
info ""

# ── 1. System packages ────────────────────────────────────────────────────────
info "Updating package lists…"
apt-get update -qq

info "Installing Python 3, pip, libusb, and git…"
apt-get install -y -qq python3 python3-pip python3-venv python3-usb libusb-1.0-0 git curl

# ── 2. Create service user ────────────────────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    info "Creating user '$SERVICE_USER'…"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# ── 3. Download bridge files ──────────────────────────────────────────────────
info "Creating install directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

for f in server.py meter_c7000_hid.py meter_mock.py requirements.txt; do
    info "Downloading $f…"
    curl -fsSL "$REPO_URL/$f" -o "$INSTALL_DIR/$f"
done

# ── 4. Python virtualenv ──────────────────────────────────────────────────────
info "Creating Python virtualenv and installing dependencies…"
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"
# pyusb needs libusb-1.0 which is installed above; also install via pip for the venv
"$INSTALL_DIR/venv/bin/pip" install --quiet pyusb

# ── 5. USB udev permissions ───────────────────────────────────────────────────
# These rules grant the 'sekonic' user USB access to the C-7000 without root.
# TODO: Replace 0x???? with actual Vendor/Product IDs from lsusb once the meter
#       is connected. Until IDs are confirmed, the rule uses a permissive fallback.
info "Installing udev rules for C-7000 USB access…"
cat > "$UDEV_FILE" << 'UDEV'
# Sekonic C-7000 Spectromaster USB HID access
# TODO: Replace idVendor and idProduct with values from: lsusb | grep -i sekonic
# SUBSYSTEM=="usb", ATTRS{idVendor}=="XXXX", ATTRS{idProduct}=="YYYY", MODE="0666", GROUP="sekonic", TAG+="uaccess"

# Fallback: allow the sekonic user to access any USB HID device (comment out after confirming IDs)
SUBSYSTEM=="usb", MODE="0664", GROUP="sekonic"
UDEV

warn "⚠️  USB udev rule uses a broad fallback. Edit $UDEV_FILE after"
warn "   running 'lsusb' with the C-7000 connected to get the exact IDs."
udevadm control --reload-rules

# ── 6. Add pi user to sekonic group (for manual testing) ─────────────────────
if id "pi" &>/dev/null; then
    usermod -aG sekonic pi
    info "Added 'pi' user to 'sekonic' group"
fi

# ── 7. systemd service ────────────────────────────────────────────────────────
info "Installing systemd service…"
curl -fsSL "$REPO_URL/sekonic-bridge.service" -o "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable sekonic-bridge
systemctl start sekonic-bridge

# ── 8. Enable SSH (for remote management) ────────────────────────────────────
info "Enabling SSH server…"
systemctl enable ssh
systemctl start ssh

# ── 9. File permissions ───────────────────────────────────────────────────────
chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/server.py"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "=== Setup complete! ==="
info ""
info "Service status: $(systemctl is-active sekonic-bridge)"
info ""
info "Check logs with:    journalctl -u sekonic-bridge -f"
info "Test the bridge:    curl http://localhost:8765/status"
info ""
IPADDR=$(hostname -I | awk '{print $1}')
info "Bridge IP on this network: $IPADDR"
info "Add to GrandMA3 config.json:"
info '  "bridge_ip":   "'$IPADDR'",'
info '  "bridge_port": 8765'
info ""
warn "Next step: connect the C-7000 via USB, run 'lsusb | grep -i sekonic'"
warn "and update $UDEV_FILE with the correct vendor/product IDs."
warn "Then: sudo systemctl restart sekonic-bridge"
