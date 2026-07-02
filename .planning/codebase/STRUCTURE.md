# Codebase Structure

**Analysis Date:** 2026-07-01

## Directory Layout

Layout varies by branch. **Current checkout** (`cursor/install-gsd-core-342d`) contains GSD/Cursor tooling only. Product code lives on remote branches documented in `.planning/codebase/_BRANCH-SCOPE.md`.

### Production baseline — `origin/claude/lighttune-main`

```text
[repo-root]/
├── plugin.xml                 # MA3 plugin manifest
├── README.md
├── .gitignore
├── lua/
│   └── SekonicCalibrator.lua  # v0.4 — monolithic plugin (~1431 lines)
├── data/
│   ├── .gitkeep
│   ├── config.json.example    # github_username only
│   └── measurements/
│       └── .gitkeep
└── test_color_math.lua        # Standalone color-math tests (dev host)
```

### Sekonic experimental — `origin/claude/sekonic-remote-api-research-HdMTl` / `origin/Lighttune-experimental`

```text
[repo-root]/
├── plugin.xml
├── README.md                  # + remote bridge workflow section
├── lua/
│   └── SekonicCalibrator.lua  # v0.5 — + bridge client & auto-loop (~2046 lines)
├── data/
│   ├── config.json.example    # + bridge_ip, bridge_port
│   └── measurements/
├── test_color_math.lua
└── sekonic-bridge/            # Raspberry Pi sidecar (NOT on lighttune-main)
    ├── README.md              # Hardware, image build, API docs
    ├── server.py              # FastAPI REST server (entry point)
    ├── meter_c7000_hid.py     # USB bulk driver for C-7000
    ├── meter_mock.py          # Mock meter for --mock / dev
    ├── discover_device.py     # CLI USB VID/PID scanner
    ├── requirements.txt       # fastapi, uvicorn, pyusb
    ├── start.sh               # Manual launcher (real or --mock)
    ├── setup-pi.sh            # Pi first-boot provisioning
    ├── build-image.sh         # Pre-built SD image builder
    ├── sekonic-bridge.service # systemd unit → /opt/sekonic-bridge
    ├── bridge.log             # Runtime log (created on Pi)
    ├── device_config.json     # Runtime USB config (created on Pi)
    └── venv/                  # Created by setup-pi.sh (not in git)
```

### Current workspace — `cursor/install-gsd-core-342d`

```text
[repo-root]/
├── .cursor/                   # GSD agents, skills, hooks, gsd-core
├── .planning/
│   └── codebase/              # Codebase map documents (this folder)
└── .gitignore
```

## Directory Purposes

**`lua/`:**
- Purpose: GrandMA3 plugin source.
- Contains: Single component file `SekonicCalibrator.lua` organized by numbered sections.
- Key sections (v0.5): 1 constants, 2 color math, 2b fixture DB JSON, **2c bridge HTTP**, 3 UI, 3b patch capabilities, 4 fixture apply, 5 data paths, 6 main.

**`data/`:**
- Purpose: Plugin-local persistence shipped with install; operator writes runtime files here.
- Contains: `config.json` (from example), `fixture_log.json` (append-only DB), optional `measurements/`.
- Not created at runtime by plugin — must exist in plugin package.

**`sekonic-bridge/` (Sekonic branches only):**
- Purpose: Pi-resident HTTP service bridging USB spectrometer to show network.
- Contains: Python server, meter drivers, deployment scripts, systemd unit.
- Installed on Pi at `/opt/sekonic-bridge` by `setup-pi.sh`.

**`.planning/codebase/`:**
- Purpose: GSD codebase intelligence (architecture, stack, concerns).
- Contains: `ARCHITECTURE.md`, `STRUCTURE.md`, `_BRANCH-SCOPE.md`, etc.

## Key File Locations

**Entry Points:**
- `plugin.xml`: MA3 plugin registration (`ComponentLua` → `lua/SekonicCalibrator.lua`).
- `lua/SekonicCalibrator.lua`: `main(display)` at Section 6; `return main` at file end.
- `sekonic-bridge/server.py`: `main()` + FastAPI `app` (Sekonic branches).
- `sekonic-bridge/start.sh`: Shell wrapper activating venv then `python3 server.py`.

**Configuration:**
- `data/config.json.example`: Template for operator `config.json` beside plugin.
- `sekonic-bridge/device_config.json`: Pi-side USB discovery state (runtime).
- `sekonic-bridge/sekonic-bridge.service`: systemd — User `sekonic`, WorkingDirectory `/opt/sekonic-bridge`.

**Core Logic:**
- Color / correction: `lua/SekonicCalibrator.lua` Section 2, `get_correction()`.
- Fixture apply: Section 4, `calibrate_group()`.
- Bridge client: Section 2c, `bridge_fetch_measurement()`, `_http_request()`.
- USB measure: `sekonic-bridge/meter_c7000_hid.py`, class `C7000HID`.

**Testing:**
- `test_color_math.lua`: Pure color-math validation off-console.
- `sekonic-bridge/meter_mock.py`: Hardware-free bridge testing (`server.py --mock`).

## SekonicCalibrator.lua Internal Map (v0.5)

| Section | Lines (approx.) | Responsibility |
|---------|-----------------|----------------|
| 1 | header–50 | Constants, meter types, quality thresholds |
| 2 | 52–200 | Color math pure functions |
| 2b | 205–378 | Fixture DB JSON encode/parse, best flags |
| 3 | 380–1120 | UI helpers, `get_measurement_params` (bridge + manual) |
| 2c | 1125–1505 | Bridge HTTP, setup wizard, `goals_met` |
| 3b | 1507–1655 | `read_capabilities_from_patch` |
| 4 | 1657–1695 | `calibrate_group`, SetColor |
| 5 | 1697–1775 | Paths, `load_config`, `save_fixture_log_local` |
| 6 | 1777–2046 | `main`, menus, auto-loop |

v0.4 omits Section 2c and bridge branches in Section 3/6; `load_config()` is slimmer.

## sekonic-bridge Module Relationships

```text
server.py
  ├── lifespan → _load_meter(use_mock)
  │     ├── meter_mock.MockMeter        (--mock)
  │     └── meter_c7000_hid.C7000HID    (default)
  ├── device_config.json ← _load_device_config / _save_device_config
  └── endpoints
        GET  /status
        GET  /discover      → pyusb scan (or mock)
        POST /capture       → test measure or passive listen
        POST /learn_trigger → probe_trigger (legacy path)
        POST /measure       → _meter.measure()

meter_c7000_hid.py
  └── reads device_config.json for VID/PID overrides (default 0x0A41 / 0x7003)

discover_device.py
  └── standalone CLI; same USB scan logic as /discover, writes device_config.json
```

## Naming Conventions

**Files:**
- Snake_case for Python (`meter_c7000_hid.py`, `discover_device.py`).
- PascalCase plugin component in XML (`SekonicCalibrator`).
- Lowercase hyphenated service name (`sekonic-bridge.service`).

**Lua:**
- `snake_case` functions and locals (`bridge_fetch_measurement`, `get_correction`).
- `SCREAMING_SNAKE` for module-level constants (`CCT_MIN`, `GOAL_MAX`).
- Section banners: `-- SECTION N: TITLE`.

**Python:**
- `snake_case` functions; `PascalCase` classes (`C7000HID`, `MockMeter`).
- Private helpers prefixed `_` (`_load_meter`, `_parse`).

## Where to Add New Code

**New spectrometer field (e.g. extra metric):**
- Parse in `sekonic-bridge/meter_c7000_hid.py` `_parse()`.
- Return from `POST /measure` in `server.py`.
- Extend `bridge_fetch_measurement` regex parsing and validation in `lua/SekonicCalibrator.lua` Section 2c.
- Update `get_measurement_params` display and `db_entry` in Section 6.

**New bridge HTTP endpoint:**
- Add route in `sekonic-bridge/server.py`.
- Call from new Lua helper in Section 2c using `_http_request`.
- Document in `sekonic-bridge/README.md`.

**New fixture capability hint:**
- Extend `read_capabilities_from_patch()` Section 3b attribute matching.
- Surface in `show_assessment()` Section 3.

**New calibration UI flow:**
- Section 3 helpers; wire from Section 6 loops.
- Preserve manual fallback when `bridge_ip` unset.

**Plugin-only change (no Pi):**
- Safe on `lighttune-main` — stay within Sections 2, 3, 4, 5, 6; do not reference Section 2c.

**Full remote-meter feature:**
- Branch from `Lighttune-experimental` or `sekonic-remote-api-research-HdMTl`; touch both `lua/` and `sekonic-bridge/`.

## Branch-Specific Paths

| Path | `lighttune-main` | Sekonic branches |
|------|------------------|------------------|
| `lua/SekonicCalibrator.lua` | v0.4 | v0.5 |
| `sekonic-bridge/` | absent | present |
| `data/config.json.example` | username only | + bridge fields |
| `README.md` | manual workflow | + Pi bridge setup |

Read files not in working tree:

```bash
git show origin/claude/sekonic-remote-api-research-HdMTl:sekonic-bridge/server.py
git show origin/claude/lighttune-main:lua/SekonicCalibrator.lua
git diff origin/claude/lighttune-main origin/claude/sekonic-remote-api-research-HdMTl
```

## Special Directories

**`data/measurements/`:**
- Purpose: Placeholder for future measurement artifacts.
- Generated: No runtime writes observed in current plugin code.
- Committed: `.gitkeep` only.

**`sekonic-bridge/venv/`:**
- Purpose: Python virtualenv on Pi.
- Generated: Yes, by `setup-pi.sh`.
- Committed: No.

**`.cursor/`:**
- Purpose: GSD workflow tooling (agents, skills, hooks).
- Generated: Installed by GSD bootstrap.
- Committed: On `cursor/install-gsd-core-342d` branch.

**`.planning/`:**
- Purpose: Project planning and codebase maps.
- Committed: Partially (codebase docs on tooling branch).

## Runtime Layout on GrandMA3 Console

Plugin installs under MA3 plugin library (OS-dependent), e.g.:

- Linux: `$HOME/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/`
- Windows: `%APPDATA%/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/`

Resolved by `get_plugin_dir()` in Section 5. Operator places `config.json` in that folder (same level as `data/`).

## Runtime Layout on Raspberry Pi

After `setup-pi.sh`:

```text
/opt/sekonic-bridge/
├── server.py
├── meter_*.py
├── venv/
├── device_config.json    # created by /discover or discover_device.py
└── bridge.log
```

Service: `systemctl enable --now sekonic-bridge` (see `sekonic-bridge.service`).

---

*Structure analysis: 2026-07-01*
