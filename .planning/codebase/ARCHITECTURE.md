<!-- refreshed: 2026-07-01 -->
# Architecture

**Analysis Date:** 2026-07-01

## System Overview

Lighttune is a **dual-component color-calibration system** for GrandMA3 lighting consoles. The **MA3 Lua plugin** (`lua/SekonicCalibrator.lua`) drives fixture correction from Sekonic spectrometer readings. On production branches it is **standalone** (manual meter entry). On Sekonic experimental branches it adds a **Raspberry Pi bridge** (`sekonic-bridge/`) that exposes the C-7000 over HTTP so the console can trigger remote measurements and auto-loop calibration.

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│                    GrandMA3 Console @ FOH (show network)                      │
│  plugin.xml → lua/SekonicCalibrator.lua → main(display)                       │
│    Sec 2   color math          Sec 4   calibrate_group() → SetColor(xyY|HSB)  │
│    Sec 3   UI / measurement    Sec 5   fixture_log.json (local append-only)   │
│    Sec 2c  bridge HTTP client  Sec 6   outer/inner calibration loops          │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ HTTP/1.0 over TCP (LuaSocket require("socket"))
                                │ POST /measure  GET /status  GET /discover …
                                ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│              Raspberry Pi bridge (sekonic-bridge/, port 8765)                 │
│  server.py (FastAPI + uvicorn) → meter backend (C7000HID | MockMeter)         │
│  device_config.json — VID/PID, protocol/trigger discovery state              │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ USB bulk (pyusb)  RT1/RM0/ST/NR/RT0 protocol
                                ▼
                        [Sekonic C-7000 USB]
```

**Branch status (see `.planning/codebase/_BRANCH-SCOPE.md`):**

| Branch | Plugin | Bridge | Status |
|--------|--------|--------|--------|
| `origin/claude/lighttune-main` | v0.4, manual entry only | absent | Production baseline |
| `origin/claude/sekonic-remote-api-research-HdMTl` | v0.5, bridge + auto-loop | full `sekonic-bridge/` | Latest Sekonic work |
| `origin/Lighttune-experimental` | v0.5 (minor Lua diffs) | merged PR #2, refined HID driver | Integration branch |
| `origin/cursor/setup-dev-environment-4246` | same as experimental | + dev env notes | Dev setup |
| `cursor/install-gsd-core-342d` (current checkout) | not present in tree | not present | GSD tooling only |

Sekonic remote API is **not merged** into `claude/lighttune-main` as of 2026-07-01.

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

**Overall:** Monolithic Lua plugin (single file, sectioned) + optional sidecar Python HTTP service on Pi.

**Key characteristics:**
- **No HTTPS on MA3:** Plugin uses raw HTTP/1.0 over LuaSocket TCP; bridge must be on trusted show LAN.
- **Manual fallback preserved:** v0.5 always allows manual Sekonic entry when bridge fails or operator chooses it.
- **Append-only fixture history:** Every measurement kept; `recompute_best_flags()` marks bests for pre-fill.
- **MA3 Patch API for GDTF:** No direct GDTF file read (`io.popen` unavailable); capabilities from `DataPool → Groups → FixtureType → DMXModes`.

## Layers

**Presentation (MA3 UI — Section 3):**
- Purpose: Operator dialogs via `MessageBox`, number inputs, session/group wizards.
- Location: `lua/SekonicCalibrator.lua` Section 3 (+ bridge status/setup in v0.5 Section 2c callers).
- Depends on: `display` handle, config, optional bridge functions.
- v0.5 adds: main menu **Bridge Status**, setup wizard, remote vs manual measurement choice.

**Domain logic (Color math — Section 2):**
- Purpose: CCT↔xy, Duv correction, quality ratings, gel hints.
- Location: `lua/SekonicCalibrator.lua` Section 2.
- Pure functions; testable via `test_color_math.lua` on a Lua host.

**Bridge client (v0.5 only — Section 2c):**
- Purpose: HTTP client, measurement fetch, status check, setup wizard HTTP calls.
- Location: `lua/SekonicCalibrator.lua` Section 2c.
- Depends on: `require("socket")`, `config.bridge_ip` / `config.bridge_port` (default 8765).

**Fixture integration (Sections 3b, 4):**
- Purpose: Read patch capabilities; select group; apply corrected xyY (fallback HSB).
- Location: `lua/SekonicCalibrator.lua` Sections 3b, 4.
- Uses: `Cmd('Group …')`, `SetColor("xyY"|"HSB", …)`.

**Persistence (Section 5):**
- Purpose: Resolve plugin paths via `GetPath(Enums.PathType.PluginLibrary)`; read/write `fixture_log.json`, `config.json`.
- Location: `lua/SekonicCalibrator.lua` Section 5.

**Bridge service (Python — Sekonic branches):**
- Purpose: FastAPI app, meter lifecycle, discovery/capture/learn endpoints, `/measure` with asyncio lock.
- Location: `sekonic-bridge/server.py`.
- Depends on: `meter_c7000_hid.C7000HID` or `meter_mock.MockMeter`.

**Hardware abstraction (Python):**
- Purpose: USB connect, remote measure sequence, parse 2380-byte NR payload.
- Location: `sekonic-bridge/meter_c7000_hid.py`.
- Protocol: `RT1` → `RM0` → poll `ST` → `NR` → `RT0` (from [skreader](https://github.com/kinglevel/skreader)).

## Data Flow

### Production path (v0.4 — `lighttune-main`)

1. Operator runs plugin from MA3 → `main(display)` (`lua/SekonicCalibrator.lua` ~1285).
2. Session goals collected → outer loop per fixture group.
3. `get_measurement_params()` prompts for CCT, Duv, CRI, R9, (TLCI if C-7000) — **manual keyboard entry**.
4. `get_correction()` computes target xy from goals vs measured.
5. `show_assessment()` → optional `calibrate_group()` → `SetColor`.
6. Inner loop repeats until `ask_group_done()`; results appended to `data/fixture_log.json`.

### Remote measurement path (v0.5 — Sekonic branches)

1. Operator configures `config.json` with `bridge_ip` and optional `bridge_port`.
2. Pi runs `server.py` (systemd `sekonic-bridge.service` or `./start.sh`); C-7000 on USB.
3. Plugin `get_measurement_params()` detects `config.bridge_ip` → offers **Remote** vs **Manual** (`~690–755`).
4. Remote: `bridge_fetch_measurement(config)` → `_http_request("POST", host, port, "/measure", 38)` (`~1168–1190`).
5. Bridge: `POST /measure` → executor runs `_meter.measure()` → USB bulk sequence → JSON `{cct, duv, cri, r9, tlci?, timestamp}`.
6. Plugin validates ranges, returns `measured` table; same correction/apply pipeline as v0.4.

### Auto-loop calibration (v0.5, bridge mode)

When `bridge_ip` is set and operator stays in remote mode (`~1844–1988`):

1. **Attempt 1:** Full measurement dialog (remote or manual choice).
2. **Attempts 2+:** Auto `bridge_fetch_measurement()` without re-prompting mode.
3. After each reading: `goals_met(measured, goals)` — CCT ±150 K, Duv within acceptable band, optional CRI/R9/TLCI mins.
4. If not met: `show_assessment()` → `calibrate_group()` → loop (max **3 cycles** per stuck window, then Accept / Try Again / Skip).
5. If met: success dialog → next group.

Manual mode unchanged: `ask_group_done()` after each attempt.

### Bridge setup / discovery flow (v0.5)

Invoked from **Bridge Status** → `run_bridge_setup()` or inline trigger discovery:

| Step | Plugin HTTP call | Bridge action |
|------|------------------|---------------|
| 1 Discover | `GET /discover` | USB scan (pyusb), save VID/PID to `device_config.json`; C-7000 (VID `0x0A41`) auto-flags protocol |
| 2 Verify | `POST /capture` | C-7000 fast path: test `measure()`; else passive bulk listen |
| 3 Trigger (optional) | `POST /learn_trigger` | Probe HID candidates (~2 min); C-7000 skips (bulk protocol known) |

Status anytime: `GET /status` → connected, `device_configured`, `protocol_captured`, `trigger_discovered`.

### End-to-end physical topology

```text
[C-7000] ──USB──► [Pi: meter_c7000_hid] ──JSON──► [MA3 plugin: bridge_fetch_measurement]
                                                      │
                                                      ▼
                                            [Fixture group in patch]
                                                      │
                                                      ▼
                                            SetColor(xyY) correction applied
                                                      │
                                                      ▼
                                            Re-measure (auto-loop until goals met)
```

## Key Abstractions

**Measurement record (Lua):**
- Purpose: Normalized spectrometer reading used by correction and DB.
- Shape: `{ cct, duv, cri, r9, tlci? }`.
- Sources: manual entry, or JSON parsed from bridge `/measure` body.

**Correction result:**
- Purpose: Target chromaticity for MA3.
- Produced by: `get_correction(tgt_cct, tgt_duv, meas_cct, meas_duv)` → `{ target_x, target_y, delta_cct, delta_duv }`.

**Meter backend (Python protocol):**
- Purpose: Pluggable driver behind `server.py`.
- Implementations: `C7000HID` (real USB), `MockMeter` (`--mock` CLI).
- Interface: `connect()`, `is_connected()`, `disconnect()`, `measure() → dict`.

**Device config persistence:**
- Purpose: Bridge self-configuration across reboots.
- File: `sekonic-bridge/device_config.json` (runtime, not in git).
- Fields: `vendor_id`, `product_id`, `configured`, `protocol_captured`, `trigger_discovered`, optional `trigger_cmd_hex`.

## Entry Points

**GrandMA3 plugin:**
- Location: `plugin.xml` → `ComponentLua` → `return main` at end of `lua/SekonicCalibrator.lua`.
- Triggers: Operator launches SekonicCalibrator from MA3 plugin pool.
- v0.4 menu: Start Calibration | View Fixture History | Cancel.
- v0.5 menu: adds **Bridge Status** (3rd button).

**Bridge HTTP server:**
- Location: `sekonic-bridge/server.py` → `main()` → `uvicorn.run(app, host, port)`.
- Triggers: systemd unit, `./start.sh`, or `python3 server.py [--mock]`.
- Default bind: `0.0.0.0:8765`.

**Standalone USB discovery:**
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

`Lighttune-experimental` vs `sekonic-remote-api-research-HdMTl`: same architecture; experimental refines `meter_c7000_hid.py` (skreader offsets), simplifies mock progression, trims redundant server discovery paths (~223 insertions / 301 deletions across 5 files).

## Architectural Constraints

- **Threading:** MA3 Lua is single-threaded; bridge uses asyncio with `run_in_executor` for blocking USB I/O and `_measurement_lock` for concurrent `/measure` rejection.
- **Global state:** Bridge module globals `_meter`, `_last_error`, `_use_mock_global`; one meter instance per server process.
- **MA3 sandbox:** No `io.popen`, `os.execute`, or HTTPS; only documented LuaSocket TCP (via `require("socket")`). Community GitHub upload not implemented.
- **Network trust:** Plain HTTP on show VLAN; no auth on bridge endpoints.
- **TLCI:** C-7000 NR response omits TLCI in standard mode; mock meter supplies it for loop testing.

## Anti-Patterns

### Assuming community upload from the console

**What happens:** Expecting the plugin to push `fixture_log.json` to GitHub from MA3.
**Why it's wrong:** GrandMA3 Lua lacks HTTPS; only plain FTP is documented.
**Do this instead:** Export `data/fixture_log.json` manually; use `github_username` as contributor label only (`log_fixture_data` in Section 5).

### Using curl/os.execute for bridge calls

**What happens:** Shelling out to HTTP clients from Lua.
**Why it's wrong:** `io.popen` / `os.execute` are unavailable in MA3.
**Do this instead:** Use Section 2c `_http_request` with LuaSocket TCP (`bridge_fetch_measurement`).

### Treating sekonic-bridge as present on main

**What happens:** Deploying Pi bridge docs while checkout is `lighttune-main`.
**Why it's wrong:** `sekonic-bridge/` exists only on Sekonic branches; main plugin has no bridge client.
**Do this instead:** Merge or checkout `Lighttune-experimental` / `sekonic-remote-api-research-HdMTl` for full stack; use v0.4 manual workflow on main.

## Error Handling

**Strategy:** `pcall` around MA3 API calls and main entry; bridge returns HTTP status + JSON `error` field; plugin surfaces `MessageBox` retry/manual/cancel flows.

**Patterns:**
- Plugin: malformed bridge JSON → `nil, "malformed_response"`; connection failure → retry / manual / cancel dialogs.
- Bridge: meter disconnected → 503; measurement timeout → 504; concurrent measure → 409.
- USB: kernel driver detach on Linux before claim; best-effort `RT0` after measure.

## Cross-Cutting Concerns

**Logging:** Bridge logs to stdout + `bridge.log`; systemd journal via `sekonic-bridge.service`.
**Validation:** Plugin clamps CCT/Duv/CRI/R9 to constants; bridge sanity-checks parsed values in discovery/capture paths.
**Authentication:** None on bridge API; physical access to show network is the security boundary.

---

*Architecture analysis: 2026-07-01*
