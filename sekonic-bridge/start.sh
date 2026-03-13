#!/usr/bin/env bash
# Sekonic Bridge — manual launcher for Linux / Raspberry Pi
# Usage:
#   ./start.sh          — start with real C-7000 hardware
#   ./start.sh --mock   — start with mock meter (no hardware needed)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Activate virtualenv if present (created by setup-pi.sh)
if [ -f "$SCRIPT_DIR/venv/bin/activate" ]; then
    source "$SCRIPT_DIR/venv/bin/activate"
fi

echo "Starting Sekonic Bridge Server…"
python3 server.py "$@"
