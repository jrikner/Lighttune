# Coding Conventions

**Analysis Date:** 2026-07-01

## Naming Patterns

**Files:**
- Plugin entry: `lua/SekonicCalibrator.lua` (PascalCase plugin name, single monolithic source file)
- Standalone tests: `test_color_math.lua` (snake_case, `test_` prefix at repo root)
- Manifest: `plugin.xml` (GrandMA3 standard)
- Example config: `data/config.json.example` (kebab/snake in path; JSON keys snake_case)

**Functions:**
- `snake_case` for all local functions: `cct_to_xy`, `get_session_goals`, `recompute_best_flags`
- Verb-led names for actions: `get_*`, `show_*`, `apply_*`, `load_*`, `save_*`, `find_*`
- Pure math/helpers use domain terms: `xy_to_uvp`, `rate_duv`, `gel_hint`
- Entry point: `main(display, ...)` returned as module export (`return main` at end of `lua/SekonicCalibrator.lua`)

**Variables:**
- `snake_case` for locals: `fixture_make`, `session_log`, `last_measured`
- Short loop/index names where scope is tight: `i`, `r`, `k`, `dk`
- Descriptive names for domain objects: `correction`, `measured`, `goals`, `caps`, `hist`

**Constants:**
- `UPPER_SNAKE` for scalar constants: `CCT_MIN`, `GOAL_SKIP`, `MODE_REFERENCE`, `METER_C7000`
- `UPPER_SNAKE` table names for grouped thresholds: `QUALITY`, `GEL_STEPS`
- String enum values in lowercase snake or short tokens: `"target"`, `"reference"`, `"c700"`, `"skip"`

**Types:**
- No explicit type system; structure conveyed via table shapes and comments
- Goal objects: `{ mode = GOAL_MAX | GOAL_MIN | GOAL_SKIP, value = number? }`
- Measurement objects: `{ cct, duv, cri, r9, tlci? }`
- Capability tables: boolean flags (`has_tint`, `has_ctb`, …) plus optional `gdtf_cri`, `gdtf_cct`
- Result objects for fixture apply: `{ success, method, error_msg }`

## Code Style

**Formatting:**
- No `.editorconfig`, Prettier, or StyLua config detected
- Indentation: 4 spaces (dominant in `lua/SekonicCalibrator.lua`)
- Test file uses tighter spacing (often single-line bodies) but same 4-space indent for blocks
- Line length: generally under ~100 chars; long `string.format` and `MessageBox` calls may span multiple lines with `..` concatenation

**Section organization:**
- Large file split by numbered banner sections:

```lua
--------------------------------------------------------------------------------
-- SECTION N: TITLE
--------------------------------------------------------------------------------
```

- Observed sections in `lua/SekonicCalibrator.lua`:
  1. CONSTANTS
  2. COLOR MATH (pure functions, no MA3 API)
  2b. FIXTURE DATABASE – JSON HELPERS
  3. UI HELPERS
  3b. FIXTURE CAPABILITY DETECTION
  4. FIXTURE APPLICATION
  5. DATA LOGGING
  6. MAIN ENTRY POINT

**Patterns to follow when adding code:**
- Put new **pure logic** in Section 2 or 2b (testable without GrandMA3)
- Put new **MessageBox / user flow** in Section 3
- Put new **Cmd / SetColor / DataPool** usage in Sections 3b, 4, or 5 as appropriate
- Wire new behavior from `main()` in Section 6

**Linting:**
- Not detected (no ESLint/StyLua/luacheck config)
- Rely on `lua5.4 test_color_math.lua` for regression on pure functions

## Import Organization

**Order:**
1. File header comment block (name, version, feature summary)
2. Constants and lookup tables
3. Pure functions (no GrandMA3 globals)
4. UI helpers
5. MA3 API integration (patch, capabilities, fixture apply)
6. I/O and config
7. `main()` and `return main`

**Dependencies:**
- No `require()` — single self-contained Lua file for the plugin
- GrandMA3 globals used directly: `MessageBox`, `Cmd`, `SetColor`, `DataPool`, `GetPath`, `GetPathSeparator`, `HostOS`, `Enums`
- Standard library only: `math`, `string`, `table`, `io`, `os`, `tonumber`, `tostring`, `pcall`

**Path resolution:**
- Use `get_plugin_dir()` → `get_data_dir()` → append filename with `get_sep()`
- Never hardcode absolute paths in new code; follow fallbacks in `get_plugin_dir()` (`lua/SekonicCalibrator.lua` lines 1211–1234)

## Error Handling

**Strategy:** Defensive wrapping around all GrandMA3 API calls; nil/false for recoverable user cancel; user-visible MessageBox for unexpected failures.

**Patterns:**

1. **`pcall` for MA3 API** — Patch reads, group select, color apply:

```lua
local ok, err = pcall(function() SetColor("xyY", x, y, 1.0, 1.0, 1.0, false) end)
if not ok then return false, tostring(err) end
```

Used in: `get_fixture_from_patch`, `read_capabilities_from_patch`, `select_group`, `apply_color_xyY`, `apply_color_hsb`, `save_fixture_log_local`, path helpers.

2. **Nil = cancel or invalid input** — UI helpers return `nil` when user cancels or validation fails after retries (typically 3 attempts in `get_number_input`, `get_group_input`, reference group name).

3. **Structured failure for fixture apply** — `calibrate_group` returns a table, never throws:

```lua
return { success = false, method = "none", error_msg = string.format("xyY: %s | HSB: %s", xy_err, hsb_err) }
```

4. **Top-level guard in `main`** — Entire calibration flow inside `pcall`; uncaught errors show `MessageBox` with `tostring(err)` (`lua/SekonicCalibrator.lua` lines 1285–1428).

5. **Silent degradation** — Missing patch data, missing config, or missing `fixture_log.json` → empty tables or `nil` caps; workflow continues without crashing.

6. **Division by zero** — Color math guards denominators (`xy_to_uvp`, `uvp_to_xy`, `xy_to_rgb` sets `y = 0.0001` when zero).

**Do this instead of:**
- Throwing errors in pure functions (they return values; callers decide)
- Using `io.popen` / `os.execute` (documented as unavailable in GrandMA3 Lua; see Section 3b and 5 comments)

## Logging

**Framework:** No logging library; user-facing output via `MessageBox` only. Tests use `print`.

**Patterns:**
- Assessment and session summary built with `string.format` + `table.concat` into multi-line messages
- No debug/trace levels in production plugin
- Fixture persistence: write full JSON array to `data/fixture_log.json` (append-only, no log rotation)

## Comments

**When to Comment:**
- File header: version, supported hardware, feature list
- Section banners for navigation in the 1400+ line file
- Non-obvious constraints (GrandMA3 API limits, GDTF detection assumptions, append-only DB schema)
- Forward references noted where needed (e.g. `apply_historical_prefill` comment about `calibrate_group`)

**JSDoc/TSDoc:**
- Not used (Lua project)
- Multi-line `--` blocks above complex functions (e.g. `read_capabilities_from_patch`, JSON schema in Section 2b)

**Spelling:**
- UI strings use British spelling: "colour", "Calibrate"
- Code identifiers use American/technical abbreviations: `color` in `apply_color_xyY`, `SetColor`

## Function Design

**Size:** Mixed — many small pure functions (5–20 lines); UI functions (`show_assessment`, `get_session_goals`) are longer due to MessageBox strings and branching.

**Parameters:** 
- UI functions take `display` as first argument (GrandMA3 display handle)
- Pure functions take primitives/tables only
- Optional context passed explicitly (`hist`, `caps`, `attempt`) rather than globals

**Return Values:**
- Pure functions: multiple return values (`return x, y`) or single table
- UI: `nil` on cancel; goal/measurement tables on success
- Booleans for simple choices (`ask_group_done` → `r == 1`)

**Local-only scope:**
- All functions declared `local function` — no exported globals except module return `main`
- Nested helpers inside encoders/UI (`local function s(k,v)`, `local function prior(...)`)

## Module Design

**Exports:**
- Plugin contract: `return main` — GrandMA3 invokes `main(display, ...)`
- No shared library module; test file duplicates Section 2/2b logic inline

**Barrel Files:**
- Not applicable (single Lua component declared in `plugin.xml`)

**JSON handling:**
- Custom regex-based JSON subset in Section 2b — not a third-party library
- Encoders: inner helpers `s`, `n`, `f`, `b` for string/number/float/bool fields
- `best_*` booleans omitted from JSON when false/nil (only `true` written)
- Parser uses `%b{}` block matching — sufficient for flat fixture records only

**Constants and magic numbers:**
- Quality thresholds live in `QUALITY` table — do not scatter literals
- Gel steps in `GEL_STEPS` with ascending thresholds
- CCT/Duv/CRI ranges as named bounds (`CCT_MIN`, `DUV_MAX`, etc.)

**Bitwise operators:**
- Code uses Lua 5.4 bitwise ops (`<<`, `>>`, `&`, `|`) in `base64_encode`/`base64_decode` — target runtime must be Lua 5.3+ (GrandMA3 embedded Lua and standalone `lua5.4` for tests)

---

*Convention analysis: 2026-07-01*
