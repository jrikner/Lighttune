# Technology Stack

**Analysis Date:** 2026-07-01

## Branch Matrix (what exists where)

| Branch | Plugin version | `sekonic-bridge/` | Remote measurement |
|--------|----------------|-------------------|--------------------|
| `origin/claude/lighttune-main` | **v0.4** (production baseline) | **Absent** | Manual meter entry only |
| `origin/claude/sekonic-remote-api-research-HdMTl` | **v0.5** (latest Sekonic work) | **Full Python bridge** | HTTP bridge + auto-loop calibration |
| `origin/Lighttune-experimental` | **v0.5** (merged PR #2) | Present (minor refactors vs research branch) | Same as research branch |
| `origin/cursor/setup-dev-environment-4246` | v0.5 + `AGENTS.md` | Present (inherits research branch) | Same; documents mock dev workflow |
| `cursor/install-gsd-core-342d` (checked out) | **v0.4** in working tree | **Absent** | GSD tooling + `.planning/codebase/` only |

Sekonic remote API is **not merged** into `origin/claude/lighttune-main` as of 2026-07-01. See `.planning/codebase/_BRANCH-SCOPE.md` for file-level deltas.

---

## Languages

**Primary (GrandMA3 plugin):**
- **Lua 5.4** — Application logic in `lua/SekonicCalibrator.lua` (~1,431 lines on v0.4 / ~2,088 lines on v0.5). GrandMA3 hosts an embedded Lua runtime with MA Lighting API bindings.
- **Standalone test Lua** — `test_color_math.lua` (~575 lines) runs outside the console with `lua5.4 test_color_math.lua` (126 tests documented in `AGENTS.md` on dev-env branch).

**Secondary (sekonic-bridge — Sekonic branches only):**
- **Python 3** — Bridge server and USB drivers in `sekonic-bridge/` (added on research/experimental branches; ~1,400+ lines across `server.py`, `meter_c7000_hid.py`, `meter_mock.py`, `discover_device.py`).
- **Bash** — Pi deployment scripts: `setup-pi.sh`, `build-image.sh`, `start.sh`.
- **XML** — Plugin manifest `plugin.xml` (GMA3 `DataVersion="1.6.1.3"`).
- **JSON** — Config, fixture database, bridge `device_config.json` (custom regex parse/encode in Lua; stdlib `json` in Python).

---

## Runtime

**GrandMA3 console (production target):**
- Embedded Lua with `MessageBox`, `Cmd`, `SetColor`, `DataPool`, `GetPath`, `HostOS`, etc.
- **Network constraint (v0.4):** No `io.popen()`, no `os.execute()`, no HTTPS — community GitHub upload disabled in source.
- **Network extension (v0.5):** LuaSocket available via `require("socket")` (documented alongside `lua.ftp` in MA3). Plugin implements raw **HTTP/1.0 over TCP** to reach the Pi bridge — not `curl`, not HTTPS.

**sekonic-bridge server (Sekonic branches):**
- **FastAPI 0.115.0** + **uvicorn 0.32.0** — async REST API on port **8765** (default).
- **pyusb 1.3.1** — USB bulk communication with C-7000 (real hardware path only).
- Runs on **Raspberry Pi OS Lite (64-bit, Bookworm)** via systemd, or any Linux/macOS host in `--mock` mode.
- **Not Flask** — stack is FastAPI/uvicorn exclusively.

**Development / CI host:**
- **Lua 5.4 CLI** — `lua5.4 test_color_math.lua` (color math unit tests).
- **Python 3.12 venv** — `sekonic-bridge/venv` with deps from `sekonic-bridge/requirements.txt` (documented in `AGENTS.md` on `origin/cursor/setup-dev-environment-4246`).
- **GSD Core** (`.cursor/` on `cursor/install-gsd-core-342d`) — project-planning tooling; not part of runtime.

**Package managers:**
- **Lua plugin:** None — zero luarocks/npm dependencies; folder copy deployment.
- **Python bridge:** `pip` inside venv (`setup-pi.sh` creates `/opt/sekonic-bridge/venv` on Pi).
- Lockfiles: `sekonic-bridge/requirements.txt` pins three packages (FastAPI, uvicorn, pyusb).

---

## Frameworks

**Core — GrandMA3 Plugin API:**
- Entry point: `return main` at end of `lua/SekonicCalibrator.lua`.
- Loaded via `plugin.xml` → `<ComponentLua FileName="lua/SekonicCalibrator.lua" />`.
- `plugin.xml` declares `Version="0.1.0"` on all branches; source header says v0.4 (main) or v0.5 (Sekonic branches).

**Core — sekonic-bridge (Sekonic branches):**
- **FastAPI** — REST endpoints (`/status`, `/measure`, `/discover`, `/capture`, `/learn_trigger`).
- **uvicorn** — ASGI server (`server.py` entry point).
- **pyusb** — USB bulk driver in `meter_c7000_hid.py` (protocol from [skreader](https://github.com/kinglevel/skreader) / Sekonic C# SDK).
- **systemd** — `sekonic-bridge.service` runs as unprivileged `sekonic` user from `/opt/sekonic-bridge`.

**Testing:**
- `test_color_math.lua` — inline harness (`assert_near`, `assert_equal`); no MA3 API.
- **MockMeter** (`sekonic-bridge/meter_mock.py`) — simulates C-7000 with converging measurement progression for integration testing without hardware.

**Build / deploy:**
- **No build toolchain** for Lua plugin — copy `SekonicCalibrator/` folder to MA3 plugin library.
- **Pi image builder** — `sekonic-bridge/build-image.sh` downloads Raspberry Pi OS Lite, injects bridge, outputs `sekonic-bridge-pi.img.gz`.
- **One-line Pi setup** — `setup-pi.sh` (apt packages, venv, udev, systemd).

---

## Key Dependencies

### GrandMA3 Lua plugin (all product branches)

| Dependency | Source | Purpose |
|------------|--------|---------|
| GrandMA3 API | Console-provided | UI, patch, color application |
| Lua stdlib | Embedded | `math`, `string`, `table`, `io.open`, `os.date` |
| LuaSocket (`socket`) | Console-provided (v0.5+) | TCP HTTP client to bridge |
| Sekonic meter (manual) | Operator | CCT/Duv/CRI/R9/TLCI via MessageBox (v0.4) |

### sekonic-bridge Python stack (Sekonic branches only)

| Package | Version | Purpose |
|---------|---------|---------|
| `fastapi` | 0.115.0 | REST API framework |
| `uvicorn[standard]` | 0.32.0 | ASGI HTTP server |
| `pyusb` | 1.3.1 | USB bulk I/O to C-7000 |

**System packages (Pi deployment via `setup-pi.sh`):**
- `python3`, `python3-pip`, `python3-venv`, `python3-usb`, `libusb-1.0-0`, `git`, `curl`

**Protocol reference (not a pip dep):**
- [kinglevel/skreader](https://github.com/kinglevel/skreader) — MIT; C-7000 USB command sequence (RT1/RM0/ST/NR/RT0), byte offsets, VID/PID hardcoded in `meter_c7000_hid.py`.

**Hardware target:**
- **Raspberry Pi Zero 2W** (recommended in `sekonic-bridge/README.md`) on stage near meter.
- **Sekonic C-7000** (primary remote target); C-700/C-800 share VID/PID `0x0A41`/`0x7003` per skreader.

---

## Configuration

### Lua plugin

| File | Branch | Fields |
|------|--------|--------|
| `data/config.json.example` | main | `github_username` |
| `data/config.json.example` | Sekonic | `github_username`, `bridge_ip`, `bridge_port` |
| `config.json` (runtime, gitignored) | all | Parsed by `load_config()` in `lua/SekonicCalibrator.lua` |

**v0.5 `load_config()` fields:** `github_username`, `bridge_ip`, `bridge_port` (defaults port to 8765).

**Data files:**
- `data/fixture_log.json` — append-only fixture database (gitignored).
- `data/measurements/*.json` — reserved (`.gitkeep` only).

### sekonic-bridge

| File | Purpose |
|------|---------|
| `sekonic-bridge/device_config.json` | Runtime USB discovery state (`vendor_id`, `product_id`, `configured`, `protocol_captured`, `trigger_discovered`) |
| CLI args | `--host`, `--port` (8765), `--mock` |
| systemd | `WorkingDirectory=/opt/sekonic-bridge`, `ExecStart=.../venv/bin/python3 server.py` |

**Environment variables:** None required; bridge binds `0.0.0.0:8765` by default.

---

## Platform Requirements

### Production — GrandMA3 console

- GrandMA3 software **v1.6+** (recommended).
- Fixture groups in showfile; GDTF via Patch API.
- Plugin install path:
  - Windows: `C:\ProgramData\MALightingTechnology\gma3_library\datapools\plugins\SekonicCalibrator\`
  - macOS/Linux: `~/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/`
- **v0.4 (main):** Operator reads Sekonic display manually.
- **v0.5 (Sekonic branches):** Console and Pi on same show network; `bridge_ip` in `config.json`.

### Production — sekonic-bridge (Pi)

- **Raspberry Pi OS Lite 64-bit** (Bookworm image URL pinned in `build-image.sh`).
- USB OTG adapter + Mini-B cable to C-7000.
- Network (WiFi or Ethernet) reachable from FOH console.
- udev rule (`/etc/udev/rules.d/99-sekonic-c7000.rules`) grants `sekonic` group USB access.
- First boot: ~5 min (package install + service enable).

### Development

| Component | Command | Branch |
|-----------|---------|--------|
| Color math tests | `lua5.4 test_color_math.lua` | all product branches |
| Mock bridge | `cd sekonic-bridge && python3 server.py --mock --port 8765` | Sekonic branches |
| Bridge status | `curl http://localhost:8765/status` | Sekonic branches |
| Mock measure | `curl -X POST http://localhost:8765/measure` | Sekonic branches |

Documented in `AGENTS.md` on `origin/cursor/setup-dev-environment-4246`: mock progression resets only on server restart; `/measure` blocks intentionally (409 on concurrent calls).

---

## Source Layout (tech-relevant)

```
# Present on origin/claude/lighttune-main (and cursor/install-gsd-core-342d working tree)
plugin.xml                    # GMA3 manifest
lua/SekonicCalibrator.lua     # v0.4 on main; v0.5 on Sekonic branches
test_color_math.lua           # Standalone Lua 5.4 tests
data/config.json.example      # bridge fields added on Sekonic branches
data/fixture_log.json         # runtime (gitignored)
data/measurements/            # reserved

# Added on Sekonic branches only (not on lighttune-main)
sekonic-bridge/
  server.py                   # FastAPI app, port 8765
  meter_c7000_hid.py          # pyusb bulk driver (skreader protocol)
  meter_mock.py               # MockMeter for --mock mode
  discover_device.py          # CLI USB VID/PID scanner
  requirements.txt            # fastapi, uvicorn, pyusb
  setup-pi.sh                 # Pi first-boot installer
  build-image.sh              # Pre-built SD image builder
  sekonic-bridge.service      # systemd unit
  start.sh                    # Manual launcher (--mock supported)
  README.md                   # Hardware shopping list, API docs, troubleshooting
```

---

## Version Notes

| Artifact | Declared version | Actual feature set |
|----------|------------------|-------------------|
| `plugin.xml` | `0.1.0` | All branches |
| Lua header (main) | v0.4 | Manual entry, local DB, no bridge |
| Lua header (Sekonic) | v0.5 | Bridge HTTP client, auto-loop, Bridge Status menu |
| Bridge `/status` JSON | `"version": "1.0.0"` | Sekonic branches |

README on main still references v0.4 and optional `curl`/`unzip`; v0.5 README documents `bridge_ip`/`bridge_port` instead of community upload.

---

*Stack analysis: 2026-07-01 — multi-branch (main + Sekonic research/experimental + dev-env + GSD install branch)*
