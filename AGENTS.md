# SekonicCalibrator / Lighttune

GrandMA3 Lua plugin (`lua/SekonicCalibrator.lua`) that calibrates fixture groups
from Sekonic spectromaster readings, plus a Python "sekonic-bridge" REST server
(`sekonic-bridge/`) that lets the console trigger USB measurements remotely.

## Cursor Cloud specific instructions

Two components are runnable/testable in this environment; the Lua *plugin* itself
is not (it requires a GrandMA3 console and its `gma` API), but the pure color-math
logic is covered by a standalone test file.

### Lua color-math unit tests
- Run from repo root: `lua5.4 test_color_math.lua` — expect `126 passed, 0 failed`.
- The test file is self-contained (inline copies of the math functions, no `require`s),
  so it runs without the GrandMA3 runtime.

### Python sekonic-bridge server
- Deps live in a virtualenv at `sekonic-bridge/venv` (created during setup; refreshed
  by the startup update script). Runtime deps are in `sekonic-bridge/requirements.txt`.
- Run in mock mode (no hardware needed) — this is the correct dev command:
  `cd sekonic-bridge && ./venv/bin/python server.py --mock --port 8765`
  (`start.sh --mock` also works and auto-activates the venv.)
- Exercise it: `curl -s http://localhost:8765/status` and `curl -s -X POST http://localhost:8765/measure`.
- Non-obvious behavior of `--mock`: the mock meter walks a fixed "bad → converged"
  progression (~4100K/CRI72 up to ~5600K/CRI95) across successive `/measure` calls,
  and the progression counter only resets when the server process is restarted. So a
  fresh server always starts at the "worst" reading; restart it to reset the sequence.
- `/measure` deliberately blocks (~1.5 s in mock, up to 35 s real) and rejects
  concurrent calls with HTTP 409 — this is intentional, not a bug.
- `pyusb` is installed but only imported inside the real-hardware endpoints; mock mode
  never touches USB, so no `libusb` system library is required for dev/testing.

### System-level notes (already provisioned in the snapshot)
- `lua5.4` and `python3.12-venv` are installed via apt (one-off; not part of the
  startup update script). If a future VM lacks them, reinstall with
  `sudo apt-get install -y lua5.4 python3.12-venv`.
