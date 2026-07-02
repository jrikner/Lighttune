<!-- gsd-project-start source:PROJECT.md -->

## Project

**Lighttune (SekonicCalibrator)**

Lighttune is a GrandMA3 plugin that calibrates fixture groups to broadcast-accurate white light using Sekonic spectrometer readings (C-700, C-800, C-7000). It is built for TV and live production crews who need consistent color across fixture groups without leaving the console workflow. v1 adds a Raspberry Pi bridge so a C-7000 on stage can be triggered over HTTP from FOH, with manual meter entry retained as fallback.

This GSD milestone **replans from scratch**: clean module boundaries and repo layout, reusing proven color math and calibration behavior from prior experiments (v0.4 main, v0.5 + sekonic-bridge on feature branches).

**Core Value:** **An operator at FOH can calibrate a fixture group in under five minutes with minimal manual typing, while hitting broadcast-grade color targets (CCT, Duv, CRI, R9, TLCI).**

If tradeoffs arise, accuracy targets are not sacrificed for speed—but the default path must be fast (remote measurement, pre-fill from history, auto-loop where safe).

### Constraints

- **Platform**: GrandMA3 Lua — no `io.popen`, no HTTPS; networking via LuaSocket (TCP HTTP/1.0 pattern validated on experimental branch)
- **Accuracy**: CCT, Duv, CRI, R9, TLCI goals must match broadcast expectations documented in README
- **Speed**: Default calibration path must minimize MessageBox typing (remote measure + history pre-fill)
- **Compatibility**: C-700/C-800 manual path must remain (no TLCI on those meters)
- **Security**: HTTP bridge on private show LAN; no secrets in git; `config.json` local-only
- **Dependencies**: Prior experimental code is reference implementation, not merge-as-is without architectural review

<!-- gsd-project-end -->

<!-- gsd-stack-start source:codebase/STACK.md -->

## Technology Stack

## Branch Matrix (what exists where)

| Branch | Plugin version | `sekonic-bridge/` | Remote measurement |
|--------|----------------|-------------------|--------------------|
| `origin/claude/lighttune-main` | **v0.4** (production baseline) | **Absent** | Manual meter entry only |
| `origin/claude/sekonic-remote-api-research-HdMTl` | **v0.5** (latest Sekonic work) | **Full Python bridge** | HTTP bridge + auto-loop calibration |
| `origin/Lighttune-experimental` | **v0.5** (merged PR #2) | Present (minor refactors vs research branch) | Same as research branch |
| `origin/cursor/setup-dev-environment-4246` | v0.5 + `AGENTS.md` | Present (inherits research branch) | Same; documents mock dev workflow |
| `cursor/install-gsd-core-342d` (checked out) | **v0.4** in working tree | **Absent** | GSD tooling + `.planning/codebase/` only |

## Languages

- **Lua 5.4** — Application logic in `lua/SekonicCalibrator.lua` (~1,431 lines on v0.4 / ~2,088 lines on v0.5). GrandMA3 hosts an embedded Lua runtime with MA Lighting API bindings.
- **Standalone test Lua** — `test_color_math.lua` (~575 lines) runs outside the console with `lua5.4 test_color_math.lua` (126 tests documented in `AGENTS.md` on dev-env branch).
- **Python 3** — Bridge server and USB drivers in `sekonic-bridge/` (added on research/experimental branches; ~1,400+ lines across `server.py`, `meter_c7000_hid.py`, `meter_mock.py`, `discover_device.py`).
- **Bash** — Pi deployment scripts: `setup-pi.sh`, `build-image.sh`, `start.sh`.
- **XML** — Plugin manifest `plugin.xml` (GMA3 `DataVersion="1.6.1.3"`).
- **JSON** — Config, fixture database, bridge `device_config.json` (custom regex parse/encode in Lua; stdlib `json` in Python).

## Runtime

- Embedded Lua with `MessageBox`, `Cmd`, `SetColor`, `DataPool`, `GetPath`, `HostOS`, etc.
- **Network constraint (v0.4):** No `io.popen()`, no `os.execute()`, no HTTPS — community GitHub upload disabled in source.
- **Network extension (v0.5):** LuaSocket available via `require("socket")` (documented alongside `lua.ftp` in MA3). Plugin implements raw **HTTP/1.0 over TCP** to reach the Pi bridge — not `curl`, not HTTPS.
- **FastAPI 0.115.0** + **uvicorn 0.32.0** — async REST API on port **8765** (default).
- **pyusb 1.3.1** — USB bulk communication with C-7000 (real hardware path only).
- Runs on **Raspberry Pi OS Lite (64-bit, Bookworm)** via systemd, or any Linux/macOS host in `--mock` mode.
- **Not Flask** — stack is FastAPI/uvicorn exclusively.
- **Lua 5.4 CLI** — `lua5.4 test_color_math.lua` (color math unit tests).
- **Python 3.12 venv** — `sekonic-bridge/venv` with deps from `sekonic-bridge/requirements.txt` (documented in `AGENTS.md` on `origin/cursor/setup-dev-environment-4246`).
- **GSD Core** (`.cursor/` on `cursor/install-gsd-core-342d`) — project-planning tooling; not part of runtime.
- **Lua plugin:** None — zero luarocks/npm dependencies; folder copy deployment.
- **Python bridge:** `pip` inside venv (`setup-pi.sh` creates `/opt/sekonic-bridge/venv` on Pi).
- Lockfiles: `sekonic-bridge/requirements.txt` pins three packages (FastAPI, uvicorn, pyusb).

## Frameworks

- Entry point: `return main` at end of `lua/SekonicCalibrator.lua`.
- Loaded via `plugin.xml` → `<ComponentLua FileName="lua/SekonicCalibrator.lua" />`.
- `plugin.xml` declares `Version="0.1.0"` on all branches; source header says v0.4 (main) or v0.5 (Sekonic branches).
- **FastAPI** — REST endpoints (`/status`, `/measure`, `/discover`, `/capture`, `/learn_trigger`).
- **uvicorn** — ASGI server (`server.py` entry point).
- **pyusb** — USB bulk driver in `meter_c7000_hid.py` (protocol from [skreader](https://github.com/kinglevel/skreader) / Sekonic C# SDK).
- **systemd** — `sekonic-bridge.service` runs as unprivileged `sekonic` user from `/opt/sekonic-bridge`.
- `test_color_math.lua` — inline harness (`assert_near`, `assert_equal`); no MA3 API.
- **MockMeter** (`sekonic-bridge/meter_mock.py`) — simulates C-7000 with converging measurement progression for integration testing without hardware.
- **No build toolchain** for Lua plugin — copy `SekonicCalibrator/` folder to MA3 plugin library.
- **Pi image builder** — `sekonic-bridge/build-image.sh` downloads Raspberry Pi OS Lite, injects bridge, outputs `sekonic-bridge-pi.img.gz`.
- **One-line Pi setup** — `setup-pi.sh` (apt packages, venv, udev, systemd).

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

- `python3`, `python3-pip`, `python3-venv`, `python3-usb`, `libusb-1.0-0`, `git`, `curl`
- [kinglevel/skreader](https://github.com/kinglevel/skreader) — MIT; C-7000 USB command sequence (RT1/RM0/ST/NR/RT0), byte offsets, VID/PID hardcoded in `meter_c7000_hid.py`.
- **Raspberry Pi Zero 2W** (recommended in `sekonic-bridge/README.md`) on stage near meter.
- **Sekonic C-7000** (primary remote target); C-700/C-800 share VID/PID `0x0A41`/`0x7003` per skreader.

## Configuration

### Lua plugin

| File | Branch | Fields |
|------|--------|--------|
| `data/config.json.example` | main | `github_username` |
| `data/config.json.example` | Sekonic | `github_username`, `bridge_ip`, `bridge_port` |
| `config.json` (runtime, gitignored) | all | Parsed by `load_config()` in `lua/SekonicCalibrator.lua` |

- `data/fixture_log.json` — append-only fixture database (gitignored).
- `data/measurements/*.json` — reserved (`.gitkeep` only).

### sekonic-bridge

| File | Purpose |
|------|---------|
| `sekonic-bridge/device_config.json` | Runtime USB discovery state (`vendor_id`, `product_id`, `configured`, `protocol_captured`, `trigger_discovered`) |
| CLI args | `--host`, `--port` (8765), `--mock` |
| systemd | `WorkingDirectory=/opt/sekonic-bridge`, `ExecStart=.../venv/bin/python3 server.py` |

## Platform Requirements

### Production — GrandMA3 console

- GrandMA3 software **v1.6+** (recommended).
- Fixture groups in showfile; GDTF via Patch API.
- Plugin install path:
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

## Source Layout (tech-relevant)

# Present on origin/claude/lighttune-main (and cursor/install-gsd-core-342d working tree)

# Added on Sekonic branches only (not on lighttune-main)

## Version Notes

| Artifact | Declared version | Actual feature set |
|----------|------------------|-------------------|
| `plugin.xml` | `0.1.0` | All branches |
| Lua header (main) | v0.4 | Manual entry, local DB, no bridge |
| Lua header (Sekonic) | v0.5 | Bridge HTTP client, auto-loop, Bridge Status menu |
| Bridge `/status` JSON | `"version": "1.0.0"` | Sekonic branches |
<!-- gsd-stack-end -->

<!-- gsd-conventions-start source:CONVENTIONS.md -->

## Conventions

## Naming Patterns

### Lua (`lua/SekonicCalibrator.lua`)

- Plugin entry: `lua/SekonicCalibrator.lua` (PascalCase plugin name, single monolithic source file)
- Standalone tests: `test_color_math.lua` (snake_case, `test_` prefix at repo root)
- Manifest: `plugin.xml` (GrandMA3 standard)
- Example config: `data/config.json.example` (JSON keys snake_case)
- `snake_case` for all local functions: `cct_to_xy`, `get_session_goals`, `recompute_best_flags`
- Verb-led names for actions: `get_*`, `show_*`, `apply_*`, `load_*`, `save_*`, `find_*`
- Pure math/helpers use domain terms: `xy_to_uvp`, `rate_duv`, `gel_hint`
- **v0.5 bridge API:** module-level forward declarations then assignment — `_http_request`, `bridge_fetch_measurement`, `goals_met`, `run_bridge_setup`, `show_bridge_status`, `_run_trigger_discovery` (defined in Section 2c, referenced from Section 3)
- Entry point: `main(display, ...)` returned as module export (`return main` at end of file)
- `snake_case` for locals: `fixture_make`, `session_log`, `last_measured`, `bridge_active`, `used_bridge`
- Short loop/index names where scope is tight: `i`, `r`, `k`, `dk`
- Descriptive names for domain objects: `correction`, `measured`, `goals`, `caps`, `hist`, `config`
- `UPPER_SNAKE` for scalar constants: `CCT_MIN`, `GOAL_SKIP`, `MODE_REFERENCE`, `METER_C7000`, `MAX_AUTO_ATTEMPTS`
- `UPPER_SNAKE` table names for grouped thresholds: `QUALITY`, `GEL_STEPS`
- String enum values in lowercase snake or short tokens: `"target"`, `"reference"`, `"c700"`, `"skip"`
- Goal objects: `{ mode = GOAL_MAX | GOAL_MIN | GOAL_SKIP, value = number? }`
- Measurement objects: `{ cct, duv, cri, r9, tlci? }`
- Config table (v0.5): `{ github_username?, bridge_ip?, bridge_port? }` — parsed by regex, not a JSON library
- Capability tables: boolean flags (`has_tint`, `has_ctb`, …) plus optional `gdtf_cri`, `gdtf_cct`

### Python (`sekonic-bridge/` — sekonic branch only)

- `server.py` — FastAPI app and CLI entry
- `meter_c7000_hid.py` — hardware driver (`C7000HID` class)
- `meter_mock.py` — dev/test backend (`MockMeter` class)
- `discover_device.py` — standalone USB scan CLI
- Shell/service: `start.sh`, `setup-pi.sh`, `build-image.sh`, `sekonic-bridge.service`
- `snake_case` with leading underscore for module-private helpers: `_load_device_config`, `_try_parse`, `_build_trigger_candidates`, `_load_cfg`, `_send_cmd`
- Public meter interface methods on classes: `connect()`, `is_connected()`, `disconnect()`, `measure()`, `probe_trigger()`
- FastAPI route handlers: async `status()`, `measure()`, `discover()`, etc.
- `PascalCase` meter backends: `C7000HID`, `MockMeter`
- Both implement the same implicit protocol: `connect() -> bool`, `is_connected() -> bool`, `disconnect()`, `measure() -> dict`
- `UPPER_SNAKE` at module level: `VENDOR_ID`, `PRODUCT_ID`, `RESPONSE_SIZE`, `ACK`, `_OFF_CCT`
- Progression tables in mock: `_CCT_STEPS`, `_DUV_STEPS` (private module constants)
- Python 3.10+ style hints where used: `-> dict`, `-> bool`, `str | None`, `list`
- Measurement dict shape (bridge ↔ plugin contract): `{"cct": int, "duv": float, "cri": int, "r9": int, "tlci": int?}`

## v0.4 vs v0.5 Lua Deltas

| Area | v0.4 (`lighttune-main`) | v0.5 (`sekonic-remote-api-research-HdMTl`) |
|------|-------------------------|---------------------------------------------|
| Version banner | `-- SekonicCalibrator v0.4` | `-- SekonicCalibrator v0.5` |
| File size | ~1431 lines | ~2046 lines (+615) |
| Main menu | 3 buttons: Start / History / Cancel | 4 buttons: adds **Bridge Status** |
| `load_config()` | `github_username` only | + `bridge_ip`, `bridge_port` (default 8765) |
| `get_measurement_params` | Returns single table | Returns `(measured, used_bridge)` tuple |
| New Section 2c | — | BRIDGE NETWORKING (LuaSocket HTTP) |
| `require("socket")` | Not used | `pcall(require, "socket")` for TCP HTTP/1.0 |
| Auto-loop calibration | Manual `ask_group_done()` only | When `bridge_ip` set: up to 3 auto bridge cycles via `goals_met()` |
| JSON response parsing | N/A | Regex on HTTP body: `body:match('"cct"%s*:%s*(%-?[%d%.]+)')` |

## Code Style

### Lua

- No `.editorconfig`, Prettier, or StyLu config detected
- Indentation: 4 spaces in `lua/SekonicCalibrator.lua`
- `test_color_math.lua` uses tighter single-line bodies but same 4-space block indent
- Long UI strings: `string.format` + `..` concatenation across lines
- Unicode in UI via UTF-8 byte escapes: `"\xe2\x80\x93"` (en-dash), `"\xe2\x98\x85"` (★)

| Section | Purpose |
|---------|---------|
| 1 | CONSTANTS |
| 2 | COLOR MATH (pure functions, no MA3 API) |
| 2b | FIXTURE DATABASE – JSON HELPERS |
| **2c** | **BRIDGE NETWORKING (LuaSocket HTTP)** — v0.5 only |
| 3 | UI HELPERS (forward decls for bridge at top) |
| 3b | FIXTURE CAPABILITY DETECTION |
| 4 | FIXTURE APPLICATION |
| 5 | DATA LOGGING + `load_config()` |
| 6 | MAIN ENTRY POINT |

- Pure logic → Section 2 or 2b (mirror in `test_color_math.lua`)
- Bridge/HTTP → Section 2c
- MessageBox flows → Section 3
- MA3 API (Cmd, DataPool) → Sections 3b, 4, 5
- Menu wiring → Section 6 `main()`

### Python

- PEP 8-ish: 4-space indent, snake_case
- Section dividers: `# ── title ──` (Unicode box-drawing dashes, 77 chars wide)
- Module docstrings at top of each `.py` file (purpose, usage, requirements)
- Type hints on public methods; bare `except Exception` in hardware paths for resilience
- `logging.basicConfig` → stdout + `bridge.log`
- Logger name: `"sekonic-bridge"` via `log = logging.getLogger(...)`
- Uvicorn access log suppressed (`log_level="warning"`); app uses own logger
- FastAPI routes are `async def`
- Blocking USB/HID work in `loop.run_in_executor(None, ...)`
- `asyncio.Lock()` (`_measurement_lock`) prevents concurrent `/measure` and `/learn_trigger`
- `HTTPException(status_code=..., detail={"error": "...", "hint": "..."})`
- JSON error bodies parsed by Lua plugin: `body:match('"error"%s*:%s*"([^"]+)"')`

## Config Patterns

### Plugin: `data/config.json.example` → `data/config.json`

- Copy `data/config.json.example` → `data/config.json` at plugin root (same directory as `plugin.xml`, **not** inside `data/`)
- `config.json` is gitignored — never commit operator IPs or usernames
- `github_username` → stored as `contributor` in `data/fixture_log.json` records
- `bridge_ip` non-empty string enables bridge UI, remote measurement, and auto-loop (no separate `auto_loop` key — behavior is implicit when IP is set)
- `bridge_port` optional; Lua defaults to **8765** when omitted: `config.bridge_port or 8765`
- Config loaded via regex in `load_config()` (`lua/SekonicCalibrator.lua` Section 5) — no JSON parser; keys must match exact string patterns

### Bridge: `sekonic-bridge/device_config.json`

## Import Organization

### Lua

- v0.4: no `require()` — fully self-contained
- v0.5: optional `require("socket")` inside `pcall` in `_http_request` only
- GrandMA3 globals: `MessageBox`, `Cmd`, `SetColor`, `DataPool`, `GetPath`, `GetPathSeparator`, `HostOS`, `Enums`
- Standard library: `math`, `string`, `table`, `io`, `os`, `tonumber`, `tostring`, `pcall`

### Python

## Error Handling

### Lua

### Python

## Comments

- File header: version, meter support, feature bullet list
- Section banners for 2000-line navigation
- v0.5 Section 2c: documents GrandMA3 TCP availability rationale (lua.ftp → socket TCP)
- Forward declarations noted at Section 3 top
- Module docstrings with endpoint list (`server.py`) or protocol sequence (`meter_c7000_hid.py`)
- Inline comments cite skreader source for byte offsets
- CLI `--mock` documented in docstring and README

## Function Design

### Lua

- UI functions: `display` as first argument
- v0.5 measurement flow: always handle `(measured, used_bridge)` return from `get_measurement_params`
- Bridge status booleans parsed from JSON substring search (not full parse)
- `goals_met(measured, goals)` — pure function in Section 2c; CCT ±150 K, Duv ± `QUALITY.DUV.acceptable`

### Python

- Meter backends: small public surface (`connect`, `measure`, …); protocol details in `_`-prefixed methods
- `MockMeter.measure()` — stateful progression via `_call_count`; resets on new instance
- Shared measurement return dict keys align with `/measure` JSON and Lua regex parsers

## Module Design

- Lua: custom regex subset in Section 2b — `best_*` flags omitted when false/nil
- Python: stdlib `json`; HTTP responses via FastAPI `JSONResponse`

<!-- gsd-conventions-end -->

<!-- gsd-architecture-start source:ARCHITECTURE.md -->

## Architecture

## System Overview

```text

```
| Branch | Plugin | Bridge | Status |
|--------|--------|--------|--------|
| `origin/claude/lighttune-main` | v0.4, manual entry only | absent | Production baseline |
| `origin/claude/sekonic-remote-api-research-HdMTl` | v0.5, bridge + auto-loop | full `sekonic-bridge/` | Latest Sekonic work |
| `origin/Lighttune-experimental` | v0.5 (minor Lua diffs) | merged PR #2, refined HID driver | Integration branch |
| `origin/cursor/setup-dev-environment-4246` | same as experimental | + dev env notes | Dev setup |
| `cursor/install-gsd-core-342d` (current checkout) | not present in tree | not present | GSD tooling only |

## Component Responsibilities

| Component | Responsibility | Branch / path |
|-----------|----------------|---------------|
| GrandMA3 plugin manifest | Registers Lua component | `plugin.xml` (all product branches) |
| SekonicCalibrator.lua | Session UI, color math, fixture apply, optional bridge client | `lua/SekonicCalibrator.lua` |
| sekonic-bridge server | REST API, USB meter control, device discovery persistence | `sekonic-bridge/server.py` (Sekonic branches only) |
| C-7000 USB driver | Bulk protocol (skreader-derived), parse NR response | `sekonic-bridge/meter_c7000_hid.py` |
| Mock meter | Simulated improving readings for dev/test | `sekonic-bridge/meter_mock.py` |
| USB discovery CLI | Standalone VID/PID scan, writes `device_config.json` | `sekonic-bridge/discover_device.py` |
| Local fixture DB | Append-only JSON history per make/model/kelvin | `data/fixture_log.json` (runtime) |
| Config | `github_username`; Sekonic branches add `bridge_ip`, `bridge_port` | `data/config.json.example` → `config.json` |

## Pattern Overview

- **No HTTPS on MA3:** Plugin uses raw HTTP/1.0 over LuaSocket TCP; bridge must be on trusted show LAN.
- **Manual fallback preserved:** v0.5 always allows manual Sekonic entry when bridge fails or operator chooses it.
- **Append-only fixture history:** Every measurement kept; `recompute_best_flags()` marks bests for pre-fill.
- **MA3 Patch API for GDTF:** No direct GDTF file read (`io.popen` unavailable); capabilities from `DataPool → Groups → FixtureType → DMXModes`.

## Layers

- Purpose: Operator dialogs via `MessageBox`, number inputs, session/group wizards.
- Location: `lua/SekonicCalibrator.lua` Section 3 (+ bridge status/setup in v0.5 Section 2c callers).
- Depends on: `display` handle, config, optional bridge functions.
- v0.5 adds: main menu **Bridge Status**, setup wizard, remote vs manual measurement choice.
- Purpose: CCT↔xy, Duv correction, quality ratings, gel hints.
- Location: `lua/SekonicCalibrator.lua` Section 2.
- Pure functions; testable via `test_color_math.lua` on a Lua host.
- Purpose: HTTP client, measurement fetch, status check, setup wizard HTTP calls.
- Location: `lua/SekonicCalibrator.lua` Section 2c.
- Depends on: `require("socket")`, `config.bridge_ip` / `config.bridge_port` (default 8765).
- Purpose: Read patch capabilities; select group; apply corrected xyY (fallback HSB).
- Location: `lua/SekonicCalibrator.lua` Sections 3b, 4.
- Uses: `Cmd('Group …')`, `SetColor("xyY"|"HSB", …)`.
- Purpose: Resolve plugin paths via `GetPath(Enums.PathType.PluginLibrary)`; read/write `fixture_log.json`, `config.json`.
- Location: `lua/SekonicCalibrator.lua` Section 5.
- Purpose: FastAPI app, meter lifecycle, discovery/capture/learn endpoints, `/measure` with asyncio lock.
- Location: `sekonic-bridge/server.py`.
- Depends on: `meter_c7000_hid.C7000HID` or `meter_mock.MockMeter`.
- Purpose: USB connect, remote measure sequence, parse 2380-byte NR payload.
- Location: `sekonic-bridge/meter_c7000_hid.py`.
- Protocol: `RT1` → `RM0` → poll `ST` → `NR` → `RT0` (from [skreader](https://github.com/kinglevel/skreader)).

## Data Flow

### Production path (v0.4 — `lighttune-main`)

### Remote measurement path (v0.5 — Sekonic branches)

### Auto-loop calibration (v0.5, bridge mode)

### Bridge setup / discovery flow (v0.5)

| Step | Plugin HTTP call | Bridge action |
|------|------------------|---------------|
| 1 Discover | `GET /discover` | USB scan (pyusb), save VID/PID to `device_config.json`; C-7000 (VID `0x0A41`) auto-flags protocol |
| 2 Verify | `POST /capture` | C-7000 fast path: test `measure()`; else passive bulk listen |
| 3 Trigger (optional) | `POST /learn_trigger` | Probe HID candidates (~2 min); C-7000 skips (bulk protocol known) |

### End-to-end physical topology

```text

```

## Key Abstractions

- Purpose: Normalized spectrometer reading used by correction and DB.
- Shape: `{ cct, duv, cri, r9, tlci? }`.
- Sources: manual entry, or JSON parsed from bridge `/measure` body.
- Purpose: Target chromaticity for MA3.
- Produced by: `get_correction(tgt_cct, tgt_duv, meas_cct, meas_duv)` → `{ target_x, target_y, delta_cct, delta_duv }`.
- Purpose: Pluggable driver behind `server.py`.
- Implementations: `C7000HID` (real USB), `MockMeter` (`--mock` CLI).
- Interface: `connect()`, `is_connected()`, `disconnect()`, `measure() → dict`.
- Purpose: Bridge self-configuration across reboots.
- File: `sekonic-bridge/device_config.json` (runtime, not in git).
- Fields: `vendor_id`, `product_id`, `configured`, `protocol_captured`, `trigger_discovered`, optional `trigger_cmd_hex`.

## Entry Points

- Location: `plugin.xml` → `ComponentLua` → `return main` at end of `lua/SekonicCalibrator.lua`.
- Triggers: Operator launches SekonicCalibrator from MA3 plugin pool.
- v0.4 menu: Start Calibration | View Fixture History | Cancel.
- v0.5 menu: adds **Bridge Status** (3rd button).
- Location: `sekonic-bridge/server.py` → `main()` → `uvicorn.run(app, host, port)`.
- Triggers: systemd unit, `./start.sh`, or `python3 server.py [--mock]`.
- Default bind: `0.0.0.0:8765`.
- Location: `sekonic-bridge/discover_device.py`.
- Triggers: Manual CLI on Pi when debugging USB enumeration.

## Branch Deltas (Plugin)

| Feature | v0.4 (`lighttune-main`) | v0.5 (Sekonic branches) |
|---------|-------------------------|-------------------------|
| Version string | `SekonicCalibrator v0.4` | `SekonicCalibrator v0.5` |
| Lines | ~1431 | ~2046 (+615) |
| `load_config()` | `github_username` only | + `bridge_ip`, `bridge_port` |
| Measurement input | Manual only | Remote via bridge + manual fallback |
| HTTP client | none | Section 2c: `_http_request`, `bridge_fetch_measurement` |
| Inner loop | `ask_group_done()` always | Auto-loop when bridge active |
| Main menu | 3 actions | 4 actions (+ Bridge Status) |
| Setup wizard | none | `run_bridge_setup`, `show_bridge_status` |

## Architectural Constraints

- **Threading:** MA3 Lua is single-threaded; bridge uses asyncio with `run_in_executor` for blocking USB I/O and `_measurement_lock` for concurrent `/measure` rejection.
- **Global state:** Bridge module globals `_meter`, `_last_error`, `_use_mock_global`; one meter instance per server process.
- **MA3 sandbox:** No `io.popen`, `os.execute`, or HTTPS; only documented LuaSocket TCP (via `require("socket")`). Community GitHub upload not implemented.
- **Network trust:** Plain HTTP on show VLAN; no auth on bridge endpoints.
- **TLCI:** C-7000 NR response omits TLCI in standard mode; mock meter supplies it for loop testing.

## Anti-Patterns

### Assuming community upload from the console

### Using curl/os.execute for bridge calls

### Treating sekonic-bridge as present on main

## Error Handling

- Plugin: malformed bridge JSON → `nil, "malformed_response"`; connection failure → retry / manual / cancel dialogs.
- Bridge: meter disconnected → 503; measurement timeout → 504; concurrent measure → 409.
- USB: kernel driver detach on Linux before claim; best-effort `RT0` after measure.

## Cross-Cutting Concerns

<!-- gsd-architecture-end -->

<!-- gsd-skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.cursor/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- gsd-skills-end -->

<!-- gsd-workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- gsd-workflow-end -->

<!-- gsd-profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- gsd-profile-end -->
