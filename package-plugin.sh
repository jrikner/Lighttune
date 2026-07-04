#!/usr/bin/env bash
# ============================================================================
# Lighttune — build the SekonicCalibrator GrandMA3 plugin folder
# ============================================================================
# The plugin's Lua code hard-codes its own folder name ("SekonicCalibrator")
# when it looks for config.json and data/, so the folder you drop into the
# GrandMA3 plugin library MUST be named exactly that — this script builds it
# for you instead of you assembling it by hand.
#
# Usage:
#   ./package-plugin.sh                # writes dist/SekonicCalibrator/
#   ./package-plugin.sh --zip          # also writes dist/SekonicCalibrator.zip
#   ./package-plugin.sh --install      # builds, then copies straight into
#                                       # the local GrandMA3 plugin library
#                                       # (auto-detected on macOS/Linux)
#   ./package-plugin.sh --install /custom/path/to/plugins
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OUT_DIR="$SCRIPT_DIR/dist/SekonicCalibrator"
DO_ZIP=false
DO_INSTALL=false
INSTALL_TARGET=""

for arg in "$@"; do
    case "$arg" in
        --zip)      DO_ZIP=true ;;
        --install)  DO_INSTALL=true ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            if [ "$DO_INSTALL" = true ] && [ -z "$INSTALL_TARGET" ]; then
                INSTALL_TARGET="$arg"
            else
                echo "Unknown option: $arg" >&2; exit 1
            fi
            ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[package]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]   ${NC} $*"; }

if command -v lua5.4 >/dev/null 2>&1; then
    info "Running host test suite (lua5.4 tests/run.lua) ..."
    lua5.4 tests/run.lua
else
    warn "lua5.4 not found — skipping host tests (install lua5.4 or run tests/run.lua manually)"
fi

info "Building $OUT_DIR ..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/lua" "$OUT_DIR/data/measurements"

cp plugin.xml "$OUT_DIR/plugin.xml"
# GrandMA3's ComponentLua FileName must be a bare filename resolved next to
# plugin.xml — the entry point goes at the plugin root, not inside lua/.
cp SekonicCalibrator.lua "$OUT_DIR/SekonicCalibrator.lua"
cp lua/*.lua "$OUT_DIR/lua/"
cp data/config.json.example "$OUT_DIR/data/config.json.example"
touch "$OUT_DIR/data/measurements/.gitkeep"

info "Plugin folder ready:"
find "$OUT_DIR" -type f | sed "s#^$SCRIPT_DIR/dist/#  #"

if [ "$DO_ZIP" = true ]; then
    ( cd "$SCRIPT_DIR/dist" && rm -f SekonicCalibrator.zip && zip -rq SekonicCalibrator.zip SekonicCalibrator )
    info "Zipped: dist/SekonicCalibrator.zip"
fi

if [ "$DO_INSTALL" = false ]; then
    echo ""
    info "Next step — copy dist/SekonicCalibrator/ into your GrandMA3 plugin library:"
    info "  Windows:      %APPDATA%\\MALightingTechnology\\gma3_library\\datapools\\plugins\\"
    info "  macOS/Linux:  ~/MALightingTechnology/gma3_library/datapools/plugins/"
    info "Then, at the plugin root (dist/SekonicCalibrator/config.json — copy from"
    info "config.json.example first), set bridge_ip/bridge_port if you're using the bridge."
    exit 0
fi

# ── --install: copy straight into the plugin library ─────────────────────────
if [ -z "$INSTALL_TARGET" ]; then
    if [ "$(uname)" = "Darwin" ] || [ "$(uname)" = "Linux" ]; then
        INSTALL_TARGET="$HOME/MALightingTechnology/gma3_library/datapools/plugins"
    else
        warn "Cannot auto-detect the plugin library path on this OS."
        warn "Re-run with an explicit path: ./package-plugin.sh --install /path/to/plugins"
        exit 1
    fi
fi

mkdir -p "$INSTALL_TARGET"
DEST="$INSTALL_TARGET/SekonicCalibrator"

if [ -d "$DEST" ]; then
    warn "Existing plugin found at $DEST"
    warn "Overwriting plugin.xml, SekonicCalibrator.lua, and lua/ — your config.json and data/ are left untouched."
    cp "$OUT_DIR/plugin.xml" "$DEST/plugin.xml"
    cp "$OUT_DIR/SekonicCalibrator.lua" "$DEST/SekonicCalibrator.lua"
    rm -rf "$DEST/lua"
    cp -R "$OUT_DIR/lua" "$DEST/lua"
    mkdir -p "$DEST/data"
    [ -f "$DEST/data/config.json.example" ] || cp "$OUT_DIR/data/config.json.example" "$DEST/data/config.json.example"
    mkdir -p "$DEST/data/measurements"
else
    cp -R "$OUT_DIR" "$DEST"
fi

info "Installed to: $DEST"
if [ ! -f "$DEST/config.json" ]; then
    warn "No config.json yet. Using the bridge? Copy the example and edit it:"
    warn "  cp '$DEST/data/config.json.example' '$DEST/config.json'"
fi
echo ""
info "In GrandMA3: Menu -> Plugin Pool -> Import -> SekonicCalibrator"
