<!-- refreshed: 2026-07-01 -->
# Architecture

**Analysis Date:** 2026-07-01

## System Overview

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                     GrandMA3 Console (Host Runtime)                      │
├─────────────────────────────────────────────────────────────────────────┤
│  plugin.xml  →  ComponentLua  →  main(display)  in SekonicCalibrator.lua│
├──────────────┬──────────────────┬───────────────────┬───────────────────┤
│  UI Layer    │  Orchestration   │  Pure Logic       │  MA3 Integration  │
│  MessageBox  │  main() loops    │  Color math       │  DataPool/Patch   │
│  wizards     │  session/group   │  JSON DB helpers  │  Cmd / SetColor   │
│  (Sec 3)     │  (Sec 6)         │  (Sec 2, 2b)      │  (Sec 3b, 4)      │
└──────┬───────┴────────┬─────────┴─────────┬─────────┴─────────┬─────────┘
       │                │                   │                   │
       ▼                ▼                   ▼                   ▼
┌──────────────┐ ┌──────────────┐ ┌─────────────────┐ ┌─────────────────────┐
│  Operator    │ │  Session     │ │  test_color_    │ │  Fixture groups     │
│  (Sekonic    │ │  state in    │ │  math.lua       │ │  in showfile patch  │
│  readings)   │ │  memory      │ │  (dev host)     │ │  (GDTF via MA3)     │
└──────────────┘ └──────┬───────┘ └─────────────────┘ └─────────────────────┘
                        │
                        ▼
              ┌─────────────────────┐
              │  Local persistence  │
              │  data/fixture_log   │
              │  .json, config.json │
              └─────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| Plugin manifest | Registers the Lua component with GrandMA3 | `plugin.xml` |
| Entry point | `main(display)` — menu, calibration orchestration, error boundary | `lua/SekonicCalibrator.lua` |
| Color math | CCT→xy, Duv correction, quality rating, gel hints (no MA3 deps) | `lua/SekonicCalibrator.lua` §2 |
| Fixture database | Append-only JSON log, best-value flags, history lookup | `lua/SekonicCalibrator.lua` §2b, §5 |
| UI wizard | MessageBox-driven prompts for goals, measurements, assessment | `lua/SekonicCalibrator.lua` §3 |
| Capability detection | Read GDTF-derived DMX attributes from MA3 Patch API | `lua/SekonicCalibrator.lua` §3b |
| Fixture control | Select group, apply xyY/HSB color correction | `lua/SekonicCalibrator.lua` §4 |
| Data I/O | Resolve plugin paths, load config, persist fixture_log.json | `lua/SekonicCalibrator.lua` §5 |
| Unit tests | Standalone Lua 5.4 tests mirroring color math and DB logic | `test_color_math.lua` |

## Pattern Overview

**Overall:** Monolithic sectioned Lua plugin — a single ~1,430-line module organized by numbered sections, exported as one GrandMA3 `ComponentLua` entry point.

**Key Characteristics:**
- All runtime code lives in one file because GrandMA3 plugins load a single Lua component per `plugin.xml` entry; there is no multi-file `require` tree in the deployed artifact.
- Pure functions (color math, JSON helpers) are colocated with MA3-coupled UI and I/O in the same file, separated by comment banners rather than packages.
- User interaction is entirely synchronous and dialog-driven via `MessageBox`; there is no event loop, web UI, or background worker.
- External hardware (Sekonic spectrometer) is out-of-band: the operator reads the meter and types values into prompts.
- Persistence is local file I/O only (`io.open`/`io.write`); network upload is explicitly out of scope due to MA3 Lua sandbox limits.

## Layers

**Constants (§1):**
- Purpose: Thresholds, mode enums, meter types, gel step tables
- Location: `lua/SekonicCalibrator.lua` lines 15–47
- Contains: `QUALITY`, `GOAL_*`, `MODE_*`, `METER_*`, `GEL_STEPS`
- Depends on: Lua standard library only
- Used by: All subsequent sections

**Pure logic — color math (§2):**
- Purpose: Chromaticity transforms and quality assessment without console APIs
- Location: `lua/SekonicCalibrator.lua` lines 49–200
- Contains: `cct_to_xy`, `get_correction`, `rate_quality`, `gel_hint`, base64 helpers
- Depends on: `math`, string/table ops
- Used by: §3 assessment UI, §4 color application, §6 orchestration

**Pure logic — fixture database (§2b):**
- Purpose: Minimal JSON encode/decode and append-only record management
- Location: `lua/SekonicCalibrator.lua` lines 202–375
- Contains: `json_parse_db_array`, `append_fixture_record`, `recompute_best_flags`, `find_best_for_fixture`
- Depends on: Pattern-matching JSON (no external JSON library)
- Used by: §5 persistence, §3 history viewer, §6 session pre-fill

**UI layer (§3):**
- Purpose: Collect session goals, measurements, and present assessment summaries
- Location: `lua/SekonicCalibrator.lua` lines 377–1047
- Contains: `get_session_goals`, `get_measurement_params`, `show_assessment`, `show_fixture_history`
- Depends on: GrandMA3 `MessageBox`, §2 math helpers
- Used by: `main()` in §6

**MA3 integration — capabilities (§3b):**
- Purpose: Infer fixture color capabilities from parsed GDTF data in the patch
- Location: `lua/SekonicCalibrator.lua` lines 1049–1148
- Contains: `read_capabilities_from_patch`, `get_fixture_from_patch`
- Depends on: `DataPool()`, `Groups`, `FixtureType`, `DMXModes` API (all wrapped in `pcall`)
- Used by: §3 hints, §6 per-group setup

**Fixture application (§4):**
- Purpose: Apply computed chromaticity to a fixture group on the console
- Location: `lua/SekonicCalibrator.lua` lines 1150–1185
- Contains: `select_group`, `apply_color_xyY`, `apply_color_hsb`, `calibrate_group`
- Depends on: `Cmd()`, `SetColor()`, §2 `xy_to_rgb`/`rgb_to_hsb`
- Used by: §6 inner loop and historical pre-apply

**Data logging (§5):**
- Purpose: Resolve plugin filesystem paths and read/write local JSON files
- Location: `lua/SekonicCalibrator.lua` lines 1187–1279
- Contains: `get_plugin_dir`, `get_data_dir`, `load_config`, `save_fixture_log_local`
- Depends on: `GetPath`, `GetPathSeparator`, `HostOS`, `io.open`
- Used by: §6 session start, post-group logging, §3 history viewer

**Orchestration (§6):**
- Purpose: Top-level workflow — menu, outer group loop, inner measure/apply loop
- Location: `lua/SekonicCalibrator.lua` lines 1281–1431
- Contains: `main(display, ...)`, `return main`
- Depends on: All prior sections
- Used by: GrandMA3 plugin runtime (invoked when operator runs the plugin)

## Data Flow

### Primary Request Path — Start Calibration

1. Operator triggers plugin → GrandMA3 loads `lua/SekonicCalibrator.lua` and calls `main(display)` (`lua/SekonicCalibrator.lua:1285`, `1431`).
2. Main menu → user selects **Start Calibration** (`lua/SekonicCalibrator.lua:1289–1307`).
3. `get_session_goals` collects meter model, calibration mode (target vs reference), CCT/Duv targets, and CRI/R9/TLCI goals (`lua/SekonicCalibrator.lua:496–575`, `1310–1311`).
4. `load_config` reads optional `config.json` for contributor name; `fixture_log.json` loaded into memory (`lua/SekonicCalibrator.lua:1245–1253`, `1313–1322`).
5. **Outer loop** — for each group:
   - `get_group_input` → `get_fixture_model_input` (patch lookup with manual fallback) (`lua/SekonicCalibrator.lua:1326–1329`).
   - `read_capabilities_from_patch` → capability table for hints (`lua/SekonicCalibrator.lua:1335`).
   - `find_best_for_fixture` → optional historical pre-apply via `calibrate_group` (`lua/SekonicCalibrator.lua:1341–1358`).
6. **Inner loop** — until operator marks group done:
   - `get_measurement_params` — operator enters Sekonic readings (`lua/SekonicCalibrator.lua:1370–1371`).
   - `get_correction` computes target xy from goals vs measured CCT/Duv (`lua/SekonicCalibrator.lua:1374–1375`).
   - `show_assessment` presents quality ratings and feature-aware hints; user chooses Apply/Skip (`lua/SekonicCalibrator.lua:1377`).
   - On Apply: `calibrate_group` → `Cmd('Group …')` then `SetColor("xyY", …)` with HSB fallback (`lua/SekonicCalibrator.lua:1379–1381`, `1176–1184`).
7. After inner loop: `log_fixture_data` appends to `data/fixture_log.json`, updates in-memory records, appends to `session_log` (`lua/SekonicCalibrator.lua:1387–1415`).
8. `ask_calibrate_another` controls outer loop exit; `show_session_summary` displays final report (`lua/SekonicCalibrator.lua:1418–1420`).

### Secondary Flow — View Fixture History

1. Main menu → **View Fixture History** (`lua/SekonicCalibrator.lua:1304–1306`).
2. `show_fixture_history` reads `data/fixture_log.json`, prompts for search, groups by Kelvin, displays tabular results with ★ best markers (`lua/SekonicCalibrator.lua:958–1047`).

### Development Test Path

1. Developer runs `lua5.4 test_color_math.lua` on a host machine (not on the console).
2. Inline copies of §2 and §2b functions are exercised with assert helpers — no MA3 APIs involved (`test_color_math.lua:57–59`).

**State Management:**
- Session state (`goals`, `session_log`, `fixture_records`) lives in `main()` local variables for the plugin invocation lifetime.
- Persistent state is append-only JSON in `data/fixture_log.json`; `best_*` flags recomputed on every write.
- No global mutable module state beyond local function closures.

## Key Abstractions

**Session goals table:**
- Purpose: Captures one calibration session's targets and quality tracking modes
- Examples: Returned by `get_session_goals` — `{ meter, mode, ref_group, cct, duv, cri, r9, tlci }` where each spectral goal is `{ mode=GOAL_MAX|GOAL_MIN|GOAL_SKIP, value? }`
- Pattern: Plain Lua tables passed through UI and orchestration layers

**Correction result:**
- Purpose: Target chromaticity and deltas for assessment display and application
- Examples: `get_correction` return — `{ target_x, target_y, delta_cct, delta_duv }`
- Pattern: Computed once per measurement attempt; consumed by `show_assessment` and `calibrate_group`

**Capabilities table:**
- Purpose: Feature flags driving conditional console/gel hints
- Examples: `{ has_tint, has_ctb, has_cto, has_rgb, has_color_wheel, has_color_wheel_filters, gdtf_cri, gdtf_cct }` from `read_capabilities_from_patch`
- Pattern: `nil` when patch API unavailable; boolean flags default false

**Fixture DB record:**
- Purpose: One spectrometer measurement tied to make/model/kelvin
- Examples: Schema documented in `README.md`; encoded by `json_encode_db_record`
- Pattern: Append-only array; `recompute_best_flags` marks winners per `(make, model, kelvin)` group

## Entry Points

**GrandMA3 plugin runtime:**
- Location: `plugin.xml` → `<ComponentLua FileName="lua/SekonicCalibrator.lua" />`
- Triggers: Operator runs plugin from Plugin Pool / assigned executor
- Responsibilities: Load Lua, invoke exported `main(display, …)`

**Lua module export:**
- Location: `lua/SekonicCalibrator.lua:1431` — `return main`
- Triggers: GrandMA3 ComponentLua loader
- Responsibilities: Single callable entry; all other functions are local

**Standalone unit test runner:**
- Location: `test_color_math.lua` (run via `lua5.4 test_color_math.lua`)
- Triggers: Developer CLI on host OS
- Responsibilities: Validate color math and DB helper parity without console

## Architectural Constraints

- **Threading:** Single-threaded synchronous Lua; each `MessageBox` blocks until the operator responds. No coroutines or async I/O.
- **Global state:** No module-level mutable globals. All functions are `local`; state scoped to `main()` locals or function parameters.
- **Circular imports:** Not applicable — monolithic single file, no `require` graph.
- **Sandbox limits:** `io.popen`, `os.execute`, and HTTPS are unavailable in GrandMA3 Lua. GDTF files cannot be read from disk; capabilities must come from the Patch API. Community upload is manual export only.
- **Filesystem:** Plugin assumes `data/` directory exists at install time; no runtime `mkdir`. Paths resolved via `GetPath(Enums.PathType.PluginLibrary)` with OS-specific fallbacks (`lua/SekonicCalibrator.lua:1211–1234`).

## Anti-Patterns

### Duplicating pure logic in tests instead of sharing a module

**What happens:** `test_color_math.lua` contains inline copies of color math and DB functions rather than `require`-ing `SekonicCalibrator.lua`.
**Why it's wrong:** Changes to §2/§2b must be manually mirrored in tests or coverage drifts.
**Do this instead:** When extracting shared logic, keep the monolithic deploy file but consider a build step or documented sync checklist; today, edits to `cct_to_xy`, `get_correction`, or JSON helpers must update both `lua/SekonicCalibrator.lua` and `test_color_math.lua`.

### Calling MA3 APIs without pcall

**What happens:** Unhandled API failures crash the plugin mid-session.
**Why it's wrong:** Patch structure varies by showfile; missing groups or attributes are common.
**Do this instead:** Wrap all `DataPool`, `Cmd`, `SetColor`, and path API calls in `pcall` as done in `read_capabilities_from_patch`, `select_group`, and `main` (`lua/SekonicCalibrator.lua:1081`, `1155`, `1286`).

### Assuming shell or network from plugin code

**What happens:** Attempts to `unzip` GDTF files or POST to GitHub fail silently or error.
**Why it's wrong:** MA3 Lua sandbox explicitly excludes these capabilities (documented in §3b and §5 comments).
**Do this instead:** Use Patch API for GDTF-derived data; document manual `fixture_log.json` export for community sharing (`README.md`, `lua/SekonicCalibrator.lua:1190–1195`).

## Error Handling

**Strategy:** Defensive `pcall` at MA3 API boundaries; top-level `pcall` in `main` catches unexpected errors and shows a single error dialog.

**Patterns:**
- API calls (`DataPool`, `Cmd`, `SetColor`, `GetPath`): wrapped in `pcall`, return `nil`/`false` + error string on failure
- User cancellation: `MessageBox` returning `nil` or Cancel button index propagates `return nil` up the wizard chain
- File I/O: silent no-op when `io.open` fails (empty records, skip logging)
- Fatal unexpected errors: caught by outer `pcall` in `main`, displayed via "Unexpected Error" MessageBox (`lua/SekonicCalibrator.lua:1423–1428`)

## Cross-Cutting Concerns

**Logging:** No structured logger. Operator-facing feedback via `MessageBox` only. Persistent audit trail via append-only `fixture_log.json`.

**Validation:** Input ranges enforced in `get_number_input` (CCT 1667–25000, Duv ±0.02, CRI/R9/TLCI 0–100) with up to 3 retry attempts (`lua/SekonicCalibrator.lua:381–393`).

**Authentication:** None. Local plugin; optional `github_username` in config is a display label only, not an auth token.

---

*Architecture analysis: 2026-07-01*
