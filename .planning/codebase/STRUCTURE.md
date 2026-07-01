# Codebase Structure

**Analysis Date:** 2026-07-01

## Directory Layout

```
/workspace/                          # Repository root (SekonicCalibrator / Lighttune)
├── plugin.xml                       # GrandMA3 plugin manifest
├── lua/
│   └── SekonicCalibrator.lua        # Entire plugin runtime (~1,430 lines)
├── data/
│   ├── .gitkeep                     # Ensures data/ exists in repo
│   ├── config.json.example          # Template for operator config
│   ├── measurements/
│   │   └── .gitkeep                 # Reserved for future per-session JSON exports
│   ├── config.json                  # Runtime config (gitignored, not in repo)
│   └── fixture_log.json             # Append-only fixture DB (gitignored, created at runtime)
├── test_color_math.lua              # Standalone Lua 5.4 unit tests
├── README.md                        # User documentation and workflow guide
├── .gitignore                       # Ignores config.json, fixture_log.json, measurements
└── .planning/
    └── codebase/                    # GSD codebase map documents (this folder)
```

**Not part of the deployable plugin artifact:** `.cursor/`, `.git/`, `.planning/` — development and planning tooling only.

## Directory Purposes

**`lua/`:**
- Purpose: GrandMA3 ComponentLua source
- Contains: Single plugin module file
- Key files: `lua/SekonicCalibrator.lua`

**`data/`:**
- Purpose: Runtime persistence directory shipped with the plugin package
- Contains: Example config, placeholder dirs, operator-generated JSON at runtime
- Key files: `data/config.json.example`, `data/fixture_log.json` (created on first calibration)

**Repository root:**
- Purpose: Plugin packaging, manifest, tests, documentation
- Contains: `plugin.xml`, `test_color_math.lua`, `README.md`
- Key files: `plugin.xml` (registers component path)

## Key File Locations

**Entry Points:**
- `plugin.xml`: GrandMA3 plugin registration — names component and Lua file path
- `lua/SekonicCalibrator.lua:1431`: `return main` — callable exported to MA3 runtime
- `test_color_math.lua`: CLI test entry — run with `lua5.4 test_color_math.lua`

**Configuration:**
- `plugin.xml`: Plugin name (`SekonicCalibrator`), author (`Lighttune`), version (`0.1.0` in manifest; code header says v0.4)
- `data/config.json.example`: Documents optional `github_username` field
- `data/config.json`: Operator-local config at plugin root sibling path — loaded from `get_plugin_dir()/config.json` (`lua/SekonicCalibrator.lua:1245–1253`), not from `data/config.json`

**Core Logic:**
- `lua/SekonicCalibrator.lua`: All production code, organized by section banners:
  - §1 Constants (lines ~15–47)
  - §2 Color math (lines ~49–200)
  - §2b Fixture database JSON (lines ~202–375)
  - §3 UI helpers (lines ~377–1047)
  - §3b Patch capability detection (lines ~1049–1148)
  - §4 Fixture application (lines ~1150–1185)
  - §5 Data logging (lines ~1187–1279)
  - §6 Main entry / orchestration (lines ~1281–1431)

**Testing:**
- `test_color_math.lua`: Mirrors §2 and §2b with assert helpers; 126 tests expected per README

**Documentation:**
- `README.md`: Installation paths, workflow, meter support, DB schema, MA3 constraints

## Naming Conventions

**Files:**
- PascalCase for the primary plugin module: `SekonicCalibrator.lua`
- snake_case for test and data files: `test_color_math.lua`, `fixture_log.json`, `config.json`
- GrandMA3 manifest: lowercase `plugin.xml`

**Functions (Lua):**
- snake_case throughout: `cct_to_xy`, `get_session_goals`, `read_capabilities_from_patch`
- `get_*` prefix for UI/data fetchers: `get_number_input`, `get_plugin_dir`
- `show_*` prefix for display-only dialogs: `show_assessment`, `show_fixture_history`
- `json_*` prefix for JSON helpers: `json_encode_db_record`, `json_parse_db_array`

**Constants:**
- UPPER_SNAKE_CASE for enums and thresholds: `GOAL_MAX`, `MODE_TARGET`, `METER_C700`, `CCT_MIN`
- Table constants in PascalCase key style: `QUALITY.CRI.excellent`

**Data fields (JSON records):**
- snake_case keys: `make`, `model`, `kelvin`, `best_cri`, `github_username`

**Directories:**
- lowercase: `lua/`, `data/`, `measurements/`
- Deploy folder name on console: `SekonicCalibrator/` (matches plugin name in manifest)

## Where to Add New Code

**New calibration feature (e.g., additional metric):**
- Primary code: `lua/SekonicCalibrator.lua` — add constants in §1, math in §2 if pure, UI prompts in §3, wire in §6 loops
- Tests: Mirror changes in `test_color_math.lua` § inline copies
- Docs: Update `README.md` feature table and schema section

**New UI dialog or wizard step:**
- Implementation: `lua/SekonicCalibrator.lua` §3 (new `local function`, call from `get_session_goals` or inner/outer loops in §6)
- Pattern: Follow existing `MessageBox({ title, message, display_handle=display, buttons={…} })` style

**New fixture capability flag:**
- Implementation: `read_capabilities_from_patch` in §3b — extend `caps` table and DMX attribute scan loop
- Consumer: `show_assessment` hint logic in §3

**New persisted field on fixture records:**
- Schema: Extend `json_encode_db_record`, `json_parse_db_array`, `append_fixture_record` in §2b
- Write path: `db_entry` construction in §6 (`lua/SekonicCalibrator.lua:1388–1399`)
- Read path: `show_fixture_history` display columns in §3

**New configuration option:**
- Example: Add field to `data/config.json.example`
- Loader: Extend `load_config()` in §5
- Note: Config file lives at plugin root (`SekonicCalibrator/config.json`), not inside `data/`

**New standalone test:**
- Add test cases to `test_color_math.lua` using `assert_near`, `assert_equal`, `assert_true` helpers
- Do not add MA3 API tests — no console runtime in CI

## Special Directories

**`data/measurements/`:**
- Purpose: Placeholder for future per-session measurement exports
- Generated: Would be runtime-written if feature added
- Committed: Only `.gitkeep`; `data/measurements/*.json` is gitignored

**`data/` (runtime files):**
- Purpose: Fixture database and optional future measurement storage
- Generated: `fixture_log.json` created on first successful group log
- Committed: Structure and example only; actual logs excluded via `.gitignore`

**`.planning/codebase/`:**
- Purpose: GSD-generated architecture and codebase intelligence documents
- Generated: By `/gsd-map-codebase` workflow
- Committed: Yes (planning artifacts for agents)

## Deploy Layout on GrandMA3 Console

When installed, the repository folder maps directly to the plugin library path:

```
gma3_library/datapools/plugins/SekonicCalibrator/
├── plugin.xml
├── lua/SekonicCalibrator.lua
├── data/
│   ├── config.json          # optional, operator-created
│   └── fixture_log.json     # created at runtime
└── config.json              # optional contributor name (plugin root, not in data/)
```

Path resolution at runtime: `GetPath(Enums.PathType.PluginLibrary) .. sep .. "SekonicCalibrator"` (`lua/SekonicCalibrator.lua:1211–1217`).

---

*Structure analysis: 2026-07-01*
