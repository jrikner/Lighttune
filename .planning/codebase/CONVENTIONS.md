# Coding Conventions

**Analysis Date:** 2026-07-01

**Branch scope:** Conventions below compare `origin/claude/lighttune-main` (SekonicCalibrator **v0.4**, production baseline) with `origin/claude/sekonic-remote-api-research-HdMTl` ( **v0.5** + `sekonic-bridge/` Python). Sekonic work is also on `origin/Lighttune-experimental` but **not merged** into `lighttune-main`.

---

## Naming Patterns

### Lua (`lua/SekonicCalibrator.lua`)

**Files:**
- Plugin entry: `lua/SekonicCalibrator.lua` (PascalCase plugin name, single monolithic source file)
- Standalone tests: `test_color_math.lua` (snake_case, `test_` prefix at repo root)
- Manifest: `plugin.xml` (GrandMA3 standard)
- Example config: `data/config.json.example` (JSON keys snake_case)

**Functions:**
- `snake_case` for all local functions: `cct_to_xy`, `get_session_goals`, `recompute_best_flags`
- Verb-led names for actions: `get_*`, `show_*`, `apply_*`, `load_*`, `save_*`, `find_*`
- Pure math/helpers use domain terms: `xy_to_uvp`, `rate_duv`, `gel_hint`
- **v0.5 bridge API:** module-level forward declarations then assignment — `_http_request`, `bridge_fetch_measurement`, `goals_met`, `run_bridge_setup`, `show_bridge_status`, `_run_trigger_discovery` (defined in Section 2c, referenced from Section 3)
- Entry point: `main(display, ...)` returned as module export (`return main` at end of file)

**Variables:**
- `snake_case` for locals: `fixture_make`, `session_log`, `last_measured`, `bridge_active`, `used_bridge`
- Short loop/index names where scope is tight: `i`, `r`, `k`, `dk`
- Descriptive names for domain objects: `correction`, `measured`, `goals`, `caps`, `hist`, `config`

**Constants:**
- `UPPER_SNAKE` for scalar constants: `CCT_MIN`, `GOAL_SKIP`, `MODE_REFERENCE`, `METER_C7000`, `MAX_AUTO_ATTEMPTS`
- `UPPER_SNAKE` table names for grouped thresholds: `QUALITY`, `GEL_STEPS`
- String enum values in lowercase snake or short tokens: `"target"`, `"reference"`, `"c700"`, `"skip"`

**Types (implicit table shapes):**
- Goal objects: `{ mode = GOAL_MAX | GOAL_MIN | GOAL_SKIP, value = number? }`
- Measurement objects: `{ cct, duv, cri, r9, tlci? }`
- Config table (v0.5): `{ github_username?, bridge_ip?, bridge_port? }` — parsed by regex, not a JSON library
- Capability tables: boolean flags (`has_tint`, `has_ctb`, …) plus optional `gdtf_cri`, `gdtf_cct`

### Python (`sekonic-bridge/` — sekonic branch only)

**Files:**
- `server.py` — FastAPI app and CLI entry
- `meter_c7000_hid.py` — hardware driver (`C7000HID` class)
- `meter_mock.py` — dev/test backend (`MockMeter` class)
- `discover_device.py` — standalone USB scan CLI
- Shell/service: `start.sh`, `setup-pi.sh`, `build-image.sh`, `sekonic-bridge.service`

**Functions:**
- `snake_case` with leading underscore for module-private helpers: `_load_device_config`, `_try_parse`, `_build_trigger_candidates`, `_load_cfg`, `_send_cmd`
- Public meter interface methods on classes: `connect()`, `is_connected()`, `disconnect()`, `measure()`, `probe_trigger()`
- FastAPI route handlers: async `status()`, `measure()`, `discover()`, etc.

**Classes:**
- `PascalCase` meter backends: `C7000HID`, `MockMeter`
- Both implement the same implicit protocol: `connect() -> bool`, `is_connected() -> bool`, `disconnect()`, `measure() -> dict`

**Constants:**
- `UPPER_SNAKE` at module level: `VENDOR_ID`, `PRODUCT_ID`, `RESPONSE_SIZE`, `ACK`, `_OFF_CCT`
- Progression tables in mock: `_CCT_STEPS`, `_DUV_STEPS` (private module constants)

**Types:**
- Python 3.10+ style hints where used: `-> dict`, `-> bool`, `str | None`, `list`
- Measurement dict shape (bridge ↔ plugin contract): `{"cct": int, "duv": float, "cri": int, "r9": int, "tlci": int?}`

---

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

**Unchanged between branches:** Sections 1–2, 2b, 3b, 4, 5 structure; color math; JSON DB helpers; `pcall` error handling; 4-space indent; British spelling in UI strings.

---

## Code Style

### Lua

**Formatting:**
- No `.editorconfig`, Prettier, or StyLu config detected
- Indentation: 4 spaces in `lua/SekonicCalibrator.lua`
- `test_color_math.lua` uses tighter single-line bodies but same 4-space block indent
- Long UI strings: `string.format` + `..` concatenation across lines
- Unicode in UI via UTF-8 byte escapes: `"\xe2\x80\x93"` (en-dash), `"\xe2\x98\x85"` (★)

**Section organization (v0.5):**

```lua
--------------------------------------------------------------------------------
-- SECTION N: TITLE
--------------------------------------------------------------------------------
```

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

**Where to add new code:**
- Pure logic → Section 2 or 2b (mirror in `test_color_math.lua`)
- Bridge/HTTP → Section 2c
- MessageBox flows → Section 3
- MA3 API (Cmd, DataPool) → Sections 3b, 4, 5
- Menu wiring → Section 6 `main()`

**Linting:** None. Use `lua5.4 test_color_math.lua` for Section 2/2b regression.

### Python

**Formatting:**
- PEP 8-ish: 4-space indent, snake_case
- Section dividers: `# ── title ──` (Unicode box-drawing dashes, 77 chars wide)
- Module docstrings at top of each `.py` file (purpose, usage, requirements)
- Type hints on public methods; bare `except Exception` in hardware paths for resilience

**Logging (`server.py`):**
- `logging.basicConfig` → stdout + `bridge.log`
- Logger name: `"sekonic-bridge"` via `log = logging.getLogger(...)`
- Uvicorn access log suppressed (`log_level="warning"`); app uses own logger

**Async patterns:**
- FastAPI routes are `async def`
- Blocking USB/HID work in `loop.run_in_executor(None, ...)`
- `asyncio.Lock()` (`_measurement_lock`) prevents concurrent `/measure` and `/learn_trigger`

**Error responses:**
- `HTTPException(status_code=..., detail={"error": "...", "hint": "..."})`
- JSON error bodies parsed by Lua plugin: `body:match('"error"%s*:%s*"([^"]+)"')`

---

## Config Patterns

### Plugin: `data/config.json.example` → `data/config.json`

**v0.4** (`origin/claude/lighttune-main`):

```json
{
  "github_username": "your_github_username"
}
```

**v0.5** (`origin/claude/sekonic-remote-api-research-HdMTl`):

```json
{
  "github_username":   "your_github_username",

  "bridge_ip":         "192.168.1.50",
  "bridge_port":       8765
}
```

**Conventions:**
- Copy `data/config.json.example` → `data/config.json` at plugin root (same directory as `plugin.xml`, **not** inside `data/`)
- `config.json` is gitignored — never commit operator IPs or usernames
- `github_username` → stored as `contributor` in `data/fixture_log.json` records
- `bridge_ip` non-empty string enables bridge UI, remote measurement, and auto-loop (no separate `auto_loop` key — behavior is implicit when IP is set)
- `bridge_port` optional; Lua defaults to **8765** when omitted: `config.bridge_port or 8765`
- Config loaded via regex in `load_config()` (`lua/SekonicCalibrator.lua` Section 5) — no JSON parser; keys must match exact string patterns

### Bridge: `sekonic-bridge/device_config.json`

**Not in git** — written at runtime by `/discover`, `discover_device.py`, or mock mode.

**Fields:** `vendor_id`, `product_id`, `manufacturer`, `product`, `configured`, `protocol_captured`, `trigger_discovered`, `trigger_cmd_hex`, `response_sample_hex`, `parse_fmt`, `parse_offset`

**Persistence:** `_save_device_config()` in `server.py` uses `json.dumps(cfg, indent=2)`; `meter_c7000_hid.py` reads via `_load_cfg()` at import and on `connect()`.

---

## Import Organization

### Lua

**Order:**
1. File header (version, features)
2. Constants
3. Pure functions (Sections 2, 2b)
4. Bridge networking (Section 2c, v0.5)
5. UI helpers
6. MA3 integration
7. I/O, config, `main()`, `return main`

**Dependencies:**
- v0.4: no `require()` — fully self-contained
- v0.5: optional `require("socket")` inside `pcall` in `_http_request` only
- GrandMA3 globals: `MessageBox`, `Cmd`, `SetColor`, `DataPool`, `GetPath`, `GetPathSeparator`, `HostOS`, `Enums`
- Standard library: `math`, `string`, `table`, `io`, `os`, `tonumber`, `tostring`, `pcall`

**Do not use:** `io.popen`, `os.execute`, `curl` — documented unavailable in GrandMA3 Lua (Section 2c comment block).

### Python

**Order in `server.py`:**
1. Docstring
2. stdlib imports
3. FastAPI / uvicorn
4. Logging setup
5. Config helpers
6. Meter backend loader
7. FastAPI app + routes
8. `main()` CLI

**Relative imports:** `from meter_mock import MockMeter`, `from meter_c7000_hid import C7000HID` (same directory; run from `sekonic-bridge/`)

**Pinned deps** (`sekonic-bridge/requirements.txt`): `fastapi==0.115.0`, `uvicorn[standard]==0.32.0`, `pyusb==1.3.1`

---

## Error Handling

### Lua

1. **`pcall` for MA3 API** — Patch, SetColor, file I/O, path helpers
2. **Nil = cancel** — UI helpers return `nil` on user cancel
3. **Bridge errors** — `(nil, err_string)` from `bridge_fetch_measurement`; user sees MessageBox with retry/manual/cancel
4. **Top-level guard** — entire `main()` in `pcall`; uncaught errors → MessageBox
5. **Silent degradation** — missing config → `nil`; missing log → empty records
6. **Range validation** — bridge response validated against `CCT_MIN`/`CCT_MAX`, `DUV_*`, `CRI_*` before accept

### Python

1. **HTTP layer** — `HTTPException` with structured `detail` dict
2. **Hardware** — try/except around USB connect; set `_last_error` global; return 503 when meter disconnected
3. **Measurement timeout** — `asyncio.wait_for(..., 35.0)` → 504 `measurement_timeout`
4. **Concurrent measure** — 409 `measurement_in_progress` when lock held
5. **Best-effort cleanup** — `RT0` disable remote mode wrapped in try/except in `C7000HID.measure()`

---

## Comments

**Lua:**
- File header: version, meter support, feature bullet list
- Section banners for 2000-line navigation
- v0.5 Section 2c: documents GrandMA3 TCP availability rationale (lua.ftp → socket TCP)
- Forward declarations noted at Section 3 top

**Python:**
- Module docstrings with endpoint list (`server.py`) or protocol sequence (`meter_c7000_hid.py`)
- Inline comments cite skreader source for byte offsets
- CLI `--mock` documented in docstring and README

**Spelling:** British in user-facing strings ("colour", "Calibrate"); American in API field names (`SetColor`, `apply_color_xyY`).

---

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

---

## Module Design

**Lua exports:** `return main` only — no shared library; tests duplicate Section 2/2b inline.

**Python:** No package `__init__.py`; scripts run from `sekonic-bridge/` directory. `server.py` selects backend at startup via `--mock` flag.

**JSON handling:**
- Lua: custom regex subset in Section 2b — `best_*` flags omitted when false/nil
- Python: stdlib `json`; HTTP responses via FastAPI `JSONResponse`

**Bitwise:** Lua 5.4 ops (`<<`, `>>`, `&`) in base64 helpers — requires Lua 5.3+ (GrandMA3 + standalone tests).

---

*Convention analysis: 2026-07-01*
