#!/usr/bin/env bash
# ============================================================================
# Sekonic Bridge — macOS Setup Script
# ============================================================================
# Primary path for Lighttune: run this on the SAME Mac as GrandMA3 onPC,
# with the Sekonic C-7000 plugged in via USB. No Raspberry Pi required.
#
# Run this from inside the sekonic-bridge/ directory of a cloned/copied
# Lighttune checkout:
#   cd sekonic-bridge
#   ./setup-mac.sh            # installs deps, sets up launchd auto-start
#   ./setup-mac.sh --mock     # same, but runs the mock meter (no hardware)
#   ./setup-mac.sh --no-service   # install deps only, skip launchd
#
# No sudo required — everything installs into this folder and the
# per-user LaunchAgents directory.
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

LABEL="com.lighttune.sekonic-bridge"
PLIST_TEMPLATE="$SCRIPT_DIR/com.lighttune.sekonic-bridge.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

USE_MOCK=false
INSTALL_SERVICE=true
for arg in "$@"; do
    case "$arg" in
        --mock)        USE_MOCK=true ;;
        --no-service)  INSTALL_SERVICE=false ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn] ${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*"; exit 1; }

[ "$(uname)" = "Darwin" ] || error "This script is for macOS only. Use setup-pi.sh on Linux/Raspberry Pi."

info "=== Sekonic Bridge Setup for macOS ==="
info "Install dir: $SCRIPT_DIR"
info ""

# ── 1. Homebrew ────────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
    error "Homebrew not found. Install it from https://brew.sh then re-run this script."
fi

# ── 2. System packages ───────────────────────────────────────────────────────
# libusb is required by pyusb to talk to the C-7000 over USB bulk transfer.
info "Installing python3 and libusb via Homebrew (skips anything already installed)…"
brew list python3 >/dev/null 2>&1 || brew install python3
brew list libusb  >/dev/null 2>&1 || brew install libusb

PYTHON_BIN="$(command -v python3)"

# ── 3. Python virtualenv ──────────────────────────────────────────────────────
info "Creating Python virtualenv and installing dependencies…"
"$PYTHON_BIN" -m venv "$SCRIPT_DIR/venv"
"$SCRIPT_DIR/venv/bin/pip" install --quiet --upgrade pip
"$SCRIPT_DIR/venv/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"

VENV_PYTHON="$SCRIPT_DIR/venv/bin/python3"

# ── 4. Quick USB sanity check ─────────────────────────────────────────────────
info "Checking USB access via pyusb/libusb…"
if "$VENV_PYTHON" -c "import usb.core; usb.core.find()" >/dev/null 2>&1; then
    info "pyusb can talk to libusb — OK"
else
    warn "pyusb could not enumerate USB devices. This is usually a missing/"
    warn "mislinked libusb. Try: brew reinstall libusb"
fi

# ── 5. launchd service (auto-start + auto-restart) ────────────────────────────
if [ "$INSTALL_SERVICE" = true ]; then
    info "Installing launchd agent ($LABEL)…"
    mkdir -p "$HOME/Library/LaunchAgents"

    PROGRAM_ARGS_EXTRA=""
    if [ "$USE_MOCK" = true ]; then
        PROGRAM_ARGS_EXTRA="<string>--mock</string>"
        info "Mock mode requested — bridge will start with --mock (no hardware needed)"
    fi

    sed \
        -e "s#__PYTHON_BIN__#$VENV_PYTHON#g" \
        -e "s#__INSTALL_DIR__#$SCRIPT_DIR#g" \
        "$PLIST_TEMPLATE" > "$PLIST_DEST"

    if [ -n "$PROGRAM_ARGS_EXTRA" ]; then
        # Insert the --mock arg into the ProgramArguments array, just before </array>
        /usr/bin/python3 - "$PLIST_DEST" <<'PYEOF'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)
data["ProgramArguments"].append("--mock")
with open(path, "wb") as f:
    plistlib.dump(data, f)
PYEOF
    fi

    # Unload any previous copy before (re)loading
    launchctl bootout "gui/$(id -u)" "$PLIST_DEST" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
    launchctl enable "gui/$(id -u)/$LABEL"

    info "Service installed. It will start now and automatically at login."
else
    info "Skipping launchd service install (--no-service). Start manually with ./start.sh"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "=== Setup complete! ==="
info ""
info "Test the bridge:    curl http://127.0.0.1:8765/status"
info ""
info "In the plugin's config.json (plugin root, next to plugin.xml):"
info '  "bridge_ip":   "127.0.0.1",'
info '  "bridge_port": 8765'
info ""
if [ "$INSTALL_SERVICE" = true ]; then
    info "Service management:"
    info "  launchctl print gui/$(id -u)/$LABEL   # status"
    info "  launchctl kickstart -k gui/$(id -u)/$LABEL   # restart"
    info "  launchctl bootout gui/$(id -u) '$PLIST_DEST'   # stop + uninstall"
    info "  tail -f bridge.log   # live log"
fi
info ""
warn "Plug the C-7000 into this Mac via USB before triggering a measurement."
