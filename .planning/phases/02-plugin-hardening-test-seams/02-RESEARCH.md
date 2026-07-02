# Phase 2: Plugin Hardening & Test Seams - Research

**Researched:** 2026-07-01  
**Domain:** GrandMA3 Lua module extraction, host-testable domain modules, fixture DB JSON hardening, single-plugin deployment  
**Confidence:** HIGH (brownfield from v0.5.0-replan monolith on `origin/claude/lighttune-main`; MA3 `require` path behavior — MEDIUM until Phase 7 console check)

## Summary

Phase 2 refactors the **2,046-line** `lua/SekonicCalibrator.lua` on `origin/claude/lighttune-main` (post Phase 1 baseline) by extracting the **domain trio** — `color_math.lua`, `fixture_db.lua`, `goals.lua` — while keeping **`plugin.xml` → single `ComponentLua`** entry unchanged [VERIFIED: `git show origin/claude/lighttune-main:plugin.xml`; section map lines 14–2046].

The monolith already isolates pure logic in Sections 2 and 2b (no MA3 API) and defines `goals_met` in Section 2c (lines 1213–1223) with a forward declaration at Section 3 (line 384) [VERIFIED: `git show` grep]. **`test_color_math.lua`** duplicates **~246 lines** (lines 57–302) of Sections 2/2b inline instead of importing shared modules — the primary drift risk Phase 2 must eliminate [VERIFIED: workspace `test_color_math.lua` line count].

**Primary recommendation:** Implement D-19 through D-39 from `02-CONTEXT.md`: add a **require+dofile loader** at the top of `SekonicCalibrator.lua`, extract the trio as `return M` tables, refactor `test_color_math.lua` to `require("color_math")` / `require("fixture_db")` / `require("goals")`, **harden fixture DB JSON only** (ARCH-02, DB-01), remove dead **base64** helpers (~35 lines), and **defer bridge JSON** hardening to Phase 5 (ARCH-04). Target **~400–500 lines** removed from the entry file; **126+** color-math assertions preserved; add **`goals_met`** host tests before sign-off (D-32).

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Module split depth (D-19)
- **D-19:** Extract the **domain trio** — minimum set for host testing and ARCH requirements:
  1. `lua/color_math.lua` — Section 2 pure functions (CCT/xy/Duv, correction, gel hints, quality rating helpers used by tests)
  2. `lua/fixture_db.lua` — Section 2b JSON helpers, `recompute_best_flags`, `append_fixture_record`, schema constants
  3. `lua/goals.lua` — `goals_met`, `goal_status_str`, and goal-mode constants (`GOAL_MIN`, `GOAL_MAX`, `GOAL_SKIP`) plus `QUALITY` thresholds they depend on
- **D-20:** Do **not** extract in Phase 2: `bridge_client` (Section 2c), `config.lua`, `patch_api` (Section 3b), `fixture_apply` (Section 4), UI (Section 3), `calibration` orchestration (Section 6), or `constants.lua` as a separate file — session/meter mode constants remain in the entry file unless pulled into `goals.lua`/`color_math.lua` as needed for module purity.
- **D-21:** Target line reduction: entry file shrinks by ~400–500 lines (Sections 2, 2b core, goals); remaining ~1,500+ lines stay until Phase 5–6.

#### Entry point & module loading (D-22)
- **D-22:** Keep **`lua/SekonicCalibrator.lua` as the sole `ComponentLua` entry** — no `main.lua` rename in Phase 2; avoids operator/docs churn and matches existing `plugin.xml`.
- **D-23:** Module loader pattern at top of entry file:
  1. Resolve plugin directory via `GetPath(Enums.PathType.PluginLibrary)` (same as `load_config()`).
  2. Prepend `plugin_dir .. "/lua/?.lua"` to `package.path`.
  3. `local color_math = require("color_math")` (and likewise for `fixture_db`, `goals`).
  4. **Fallback:** if `require` fails (host tests or MA3 path quirks), `dofile(plugin_dir .. "/lua/color_math.lua")` with identical return-table contract.
- **D-24:** Each extracted module returns a table (`return M`); no MA3 API calls at module top level. Entry file re-exports or calls `M.function` — no global pollution of `_G`.
- **D-25:** Host test runner uses `package.path` pointing at `lua/` (repo-relative) so `require("color_math")` works without MA3; **no duplicated inline copies** in `test_color_math.lua` after Phase 2.

#### JSON hardening scope (D-26)
- **D-26:** **Incremental harden fixture DB JSON only** (ARCH-02, DB-01) — replace fragile regex-only paths with structured encode/decode for the known flat-array schema:
  - Escape `"`, `\`, and control chars in string fields (`make`, `model`, `contributor`, `date`)
  - Reject or skip malformed records with logged/visible error instead of silent `{}`
  - Preserve append-only array shape and `best_*` flag semantics unchanged
- **D-27:** Keep regex-based field extractors only as **internal fallback** inside `fixture_db.lua` if a record block fails structured parse — do not expose two public APIs.
- **D-28:** **Defer bridge response JSON hardening** (Section 2c `_http_request` / `bridge_fetch_measurement` regex parses) to **Phase 5** when `bridge_client.lua` is extracted (ARCH-04). Phase 2 may touch bridge code only for `require` wiring if goals/constants move — not for JSON refactor.
- **D-29:** No external JSON library dependency — MA3 may lack one; hand-rolled encoder with explicit schema is acceptable if hardened.

#### Goals & assessment isolation (D-30)
- **D-30:** **ARCH-03 satisfied by pure function extraction** to `goals.lua`:
  - `goals_met(measured, goals)` — auto-loop gate (Phase 5 depends on this)
  - `goal_status_str(measured_val, goal)` — assessment strings
  - Supporting constants: `QUALITY`, `GOAL_*` modes
- **D-31:** **Assessment UI stays in monolith** — `show_assessment`, `rate_quality`, `rate_duv`, MessageBox flows remain in `SekonicCalibrator.lua` Section 3; they **call into** `goals` and `color_math` but are not extracted in Phase 2.
- **D-32:** Add host tests for `goals_met` edge cases (TLCI nil, GOAL_SKIP, CCT ±150 K boundary, Duv tolerance) in Phase 2 or Phase 3 — at minimum preserve existing 126+ color-math assertions and add goals coverage before Phase 2 sign-off.

#### Cleanup & test layout (D-33)
- **D-33:** **Remove dead code:** `base64_encode`, `base64_decode`, and `B64_*` lookup tables (~35 lines) — unused since community upload removal (0530fd2).
- **D-34:** **Test file location for Phase 2:** keep `test_color_math.lua` at **repo root** — refactor to `require` shared modules; rename optional in Phase 3 when CI adds `tests/run.lua`.
- **D-35:** **`data/measurements/`:** leave untouched — directory is reserved/unused; no create/delete in Phase 2 unless `.gitignore` already covers it.
- **D-36:** Remove stale header comments referencing community upload if still present after extraction.
- **D-37:** Phase 2 execution target: **`claude/lighttune-main`** (post Phase 1 baseline `91b322c` or later); planning artifacts stay on `cursor/install-gsd-core-342d`.

#### Single-plugin artifact (D-38, ARCH-05)
- **D-38:** `plugin.xml` continues to declare **one** `ComponentLua` → `lua/SekonicCalibrator.lua`. New files under `lua/` are sibling modules, not additional plugin components.
- **D-39:** Calibration intelligence (color math, goals, fixture DB, future bridge client) remains **on-console** — no logic moves to Pi in this phase.

### Claude's Discretion
- Exact split of `rate_quality` / `rate_duv` between `color_math.lua` vs entry file (prefer `color_math` if host-tested).
- Whether `GOAL_*` / `MODE_*` / `METER_*` constants live in `goals.lua` or a tiny shared snippet — must not create circular requires.
- Host test file naming (`test_goals.lua` vs extended `test_color_math.lua`) — defer unified runner to Phase 3.
- `plugin.xml` Version bump (stay `0.5.0` vs patch `0.5.1-replan`) — note in README/Lua header only if semver unchanged.

### Deferred Ideas (OUT OF SCOPE)
- `bridge_client.lua` + bridge JSON parser — **Phase 5** (ARCH-04)
- `config.lua`, `patch_api.lua`, `fixture_apply.lua`, `ui/*`, `calibration.lua` — **Phase 5–6**
- `main.lua` entry rename — only if MA3 requires it after console `require` verification (**Phase 7** UAT)
- `tests/run.lua` unified runner + golden fixtures — **Phase 3**
- Full structured JSON library or MA3 native JSON — evaluate if hand-rolled hardening insufficient
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ARCH-01 | Color math extracted to testable Lua module (`color_math.lua`) shared by plugin and host tests | Section 2 functions (lines 52–204) map 1:1 to `color_math.lua`; host tests replace inline copy with `require("color_math")`; module returns table per D-24 |
| ARCH-02 | Fixture database logic extracted to module with hardened JSON parse/encode (not regex-only) | Section 2b (lines 205–379) → `fixture_db.lua`; hardened `json_escape` + structured encode/decode; regex retained as internal fallback only (D-27); bridge JSON untouched (D-28) |
| ARCH-03 | Goals and quality assessment logic isolated from UI and transport layers | `goals_met` (Section 2c L1213–1223) + `goal_status_str` (Section 2 L140–149) + `QUALITY`/`GOAL_*` → `goals.lua`; UI assessment functions stay in Section 3, call module APIs (D-31) |
| ARCH-05 | Plugin ships as **one deployable MA3 plugin**; calibration logic stays on-console | `plugin.xml` unchanged single `ComponentLua`; sibling modules under `lua/` loaded via `require`/`dofile` (D-22, D-38); no Pi logic migration (D-39) |
| DB-01 | Append-only `fixture_log.json` with best-value flags per make/model/kelvin | `recompute_best_flags`, `append_fixture_record`, `sort_fixture_records`, `find_best_for_fixture` move to `fixture_db.lua`; semantics unchanged; hardened parse surfaces corrupt records instead of silent drop |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| CCT/xy/Duv correction math | `color_math.lua` (domain) | Host tests via `require` | Pure functions; 126+ existing assertions; no MA3 API |
| Fixture DB encode/parse/flags | `fixture_db.lua` (domain) | Section 5 I/O in monolith | Pure logic extracted; file read/write stays in entry until `config.lua` (Phase 5–6) |
| Goal pass/fail + status strings | `goals.lua` (domain) | Auto-loop in Section 6 (Phase 5) | `goals_met` is auto-loop gate; must be host-testable before HTTP integration |
| Quality rating bands (`rate_*`) | `color_math.lua` (recommended) | Section 3 UI callers | Host-tested today; UI only displays strings (D-31) |
| Bridge HTTP client | Monolith Section 2c | Pi transport | ARCH-04 deferred; forward decl pattern preserved |
| Session/meter/mode constants | Entry file Section 1 | — | `MODE_*`, `METER_*`, `STAR` stay until later phase (D-20) |
| Assessment & MessageBox UI | Monolith Section 3 | Calls domain modules | Highest MA3 coupling; Phase 6 split |
| Patch API / SetColor apply | Monolith Sections 3b–4 | — | Console-only; not host-testable |
| Config + fixture log I/O | Monolith Section 5 | — | Uses `fixture_db` encode/parse; path logic unchanged |
| Plugin packaging | `plugin.xml` + entry loader | — | Single deployable artifact (ARCH-05) |

### Target layout (Phase 2 subset of full architecture)

```text
SekonicCalibrator/
├── plugin.xml                          # ComponentLua → lua/SekonicCalibrator.lua ONLY
├── config.json                         # runtime (plugin root)
├── lua/
│   ├── SekonicCalibrator.lua           # ~1,500+ lines: loader + §1 + §2c + §3–6
│   ├── color_math.lua                  # NEW — Section 2 pure math
│   ├── fixture_db.lua                  # NEW — Section 2b + hardened JSON
│   └── goals.lua                       # NEW — goals_met, goal_status_str, QUALITY, GOAL_*
├── data/
│   ├── config.json.example
│   └── fixture_log.json                # runtime append-only DB
└── test_color_math.lua                 # refactored: require modules, no inline copy
```

[VERIFIED: full multi-file layout in `.planning/research/ARCHITECTURE.md`; Phase 2 implements **domain trio only** per D-19/D-20]

### Section map (main branch, pre-extraction)

| Section | Lines | Phase 2 disposition |
|---------|-------|---------------------|
| 1 CONSTANTS | 14–51 | Partial stay: `MODE_*`, `METER_*`, `STAR`; move `QUALITY`, `GOAL_*`, `GEL_STEPS`, CCT/DUV bounds to modules |
| 2 COLOR MATH | 52–204 | → `color_math.lua` (+ remove base64 dead code) |
| 2b FIXTURE DB | 205–379 | → `fixture_db.lua` |
| 3 UI HELPERS | 380–1124 | Stay; drop `goals_met` forward decl; call `goals.*` |
| 2c BRIDGE | 1125–1508 | Stay; remove inline `goals_met` assignment; `require("goals")` |
| 3b PATCH | 1509–1609 | Stay |
| 4 APPLY | 1610–1646 | Stay |
| 5 LOGGING | 1647–1746 | Stay; call `fixture_db.*` |
| 6 MAIN | 1747–2046 | Stay |

[VERIFIED: `git show origin/claude/lighttune-main:lua/SekonicCalibrator.lua` section grep]

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| **Framework** | Standalone Lua 5.4 harness (`test_color_math.lua` at repo root) |
| **Module path** | `package.path = package.path .. ";./lua/?.lua"` (host); entry file sets `plugin_dir/lua/?.lua` (console) |
| **Config file** | none |
| **Quick run command** | `lua5.4 test_color_math.lua` |
| **Full suite command** | same (Phase 2); Phase 3 adds `tests/run.lua` |
| **Estimated runtime** | ~5 seconds |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ARCH-01 | Color math single source | unit | `lua5.4 test_color_math.lua` (126+ PASS) | ✅ |
| ARCH-01 | No inline Section 2 duplicate | grep | `! grep -q "Inline copies" test_color_math.lua` | post-Phase 2 |
| ARCH-02 | JSON roundtrip + escape quotes | unit | tests in `test_color_math.lua` fixture_db sections | ✅ (extend for `"` in make) |
| ARCH-02 | Malformed record skipped with error | unit | new fixture_db tests (Phase 2) | ❌ add |
| ARCH-03 | `goals_met` CCT ±150 K boundary | unit | new section in test file or `test_goals.lua` | ❌ add (D-32) |
| ARCH-03 | `goals_met` TLCI nil + GOAL_SKIP | unit | same | ❌ add |
| ARCH-05 | Single plugin.xml entry | grep | `grep -c ComponentLua plugin.xml` → 1 | ✅ |
| ARCH-05 | Sibling modules load on host | unit | `require("color_math")` in test runner | post-Phase 2 |
| DB-01 | `recompute_best_flags` semantics | unit | existing tests via `fixture_db` require | ✅ |
| DB-01 | Append-only (no delete on write) | unit | `append_fixture_record` tests | ✅ |

### Sampling Rate

- **After every extraction commit:** `lua5.4 test_color_math.lua` must stay green
- **After module wiring:** grep entry file for removed Section 2/2b function bodies (should be `color_math.` / `fixture_db.` / `goals.` calls only)
- **After JSON harden:** add at least one test with `"` in `make`/`model` string fields
- **Before Phase 2 sign-off:** 126+ color-math PASS + new `goals_met` cases + entry file line count reduced ~400–500
- **Max feedback latency:** 30 seconds (host tests)

### Wave 0 Gaps

- [ ] `lua5.4` on executor host — required for gate (same as Phase 1)
- [ ] `goals_met` host tests — **mandatory before sign-off** (D-32); currently **zero coverage** [VERIFIED: no `goals_met` in `test_color_math.lua`]
- [ ] MA3 console `require` verification — deferred to Phase 7 UAT; **dofile fallback** mitigates (D-23)

## Technical Patterns

### Pattern 1: Module loader (entry file top)

**What:** Resolve plugin dir, extend `package.path`, `require` domain trio, fallback `dofile`.  
**When:** First executable lines after header comment in `SekonicCalibrator.lua`.  
**Why:** MA3 may or may not resolve sibling modules; host tests have no `GetPath`.

```lua
-- Module loader (D-23) — no MA3 API in extracted modules; loader may call GetPath
local function load_domain_modules()
    local plugin_dir
    if GetPath and Enums then
        local ok, dir = pcall(function()
            return GetPath(Enums.PathType.PluginLibrary)
        end)
        if ok and dir then plugin_dir = dir end
    end
    if plugin_dir then
        package.path = plugin_dir .. "/lua/?.lua;" .. package.path
    end
    local function try_require(name)
        local ok, mod = pcall(require, name)
        if ok then return mod end
        if plugin_dir then
            return dofile(plugin_dir .. "/lua/" .. name .. ".lua")
        end
        error("module " .. name .. " not found")
    end
    return try_require("color_math"), try_require("fixture_db"), try_require("goals")
end

local color_math, fixture_db, goals = load_domain_modules()
```

[ASSUMED: `dofile` return value equals `require` return table — enforce `return M` in each module]

### Pattern 2: `require` on GrandMA3

**What:** Standard Lua 5.4 `require` with `package.path` including `plugin_dir/lua/?.lua`.  
**Evidence:** GMA3 documents LuaSocket via `lua.ftp` → TCP/`socket` available; multi-file plugins use folder layout with sibling `.lua` files [CITED: `.planning/research/ARCHITECTURE.md`, AGENTS.md].  
**Risk (MEDIUM):** Exact `package.path` behavior on embedded MA3 runtime not verified in this session.  
**Mitigation:** D-23 `dofile` fallback; Phase 7 UAT gate before removing fallback.

**Host test bootstrap:**

```lua
package.path = package.path .. ";./lua/?.lua"
local color_math = require("color_math")
local fixture_db = require("fixture_db")
local goals      = require("goals")
```

### Pattern 3: Module return contract (`return M`)

Each module ends with exported table; no `_G` pollution (D-24):

```lua
-- color_math.lua
local M = {}
M.cct_to_xy = cct_to_xy
M.get_correction = get_correction
-- ...
return M
```

Entry file uses local aliases for readability: `local cct_to_xy = color_math.cct_to_xy` (optional) or direct `color_math.cct_to_xy(...)` at call sites.

### Pattern 4: JSON hardening (fixture DB only)

**Scope:** `fixture_db.lua` public API — `encode_db_array`, `parse_db_array` (rename from `json_*` optional; keep call-site compatibility in entry file via aliases).

**Encode hardening (D-26):**

```lua
local function json_escape_str(s)
    return (tostring(s):gsub('[\\"\x00-\x1f]', {
        ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n',
        ['\r'] = '\\r', ['\t'] = '\\t',
    }))
end
-- Apply to make, model, contributor, date in json_encode_db_record
```

**Parse hardening:**

1. Primary: structured block scan with escaped-string-aware field extraction (hand-rolled, schema-fixed).
2. On per-record failure: increment `skipped` counter, optionally collect error string; **do not** silently omit without trace.
3. Fallback (D-27): if primary fails for a `{...}` block, retry legacy `json_get_*` regex on that block only — internal, not exported.
4. Entry file `save_fixture_log_local` / history viewer: surface parse warnings via `MessageBox` when `skipped > 0` [ASSUMED: acceptable UX for corrupt local DB].

**Out of scope:** Bridge `bridge_fetch_measurement` regex (D-28) — unchanged in Phase 2.

### Pattern 5: Forward declarations after `goals_met` extraction

**Current (main):** Section 3 declares `local goals_met` (L384); Section 2c assigns `goals_met = function(...)` (L1213).

**Target (Phase 2):**

```lua
-- SECTION 3: UI HELPERS
-- Forward declarations for bridge functions (Section 2c, below).
local _http_request
local bridge_fetch_measurement
local run_bridge_setup
local show_bridge_status
local _run_trigger_discovery
-- goals_met: loaded from goals module at file top — NO forward decl
```

Section 2c **removes** `goals_met = function` block; all call sites use `goals.goals_met(measured, session_goals)`.

Bridge forward-decl pattern **unchanged** — Section 3 references bridge functions before Section 2c defines them [VERIFIED: lines 380–387, 1125+].

### Pattern 6: Eliminate test duplication

**Before:** `test_color_math.lua` lines 57–302 inline copy (~246 lines).  
**After:** ~40 lines of `require` + harness; tests call `color_math.cct_to_xy`, `fixture_db.json_parse_db_array`, etc.

Remove duplicated **base64** tests (D-33) — dead code removed from production; tests for base64 are no longer valuable.

### Anti-Patterns to Avoid

| Anti-pattern | Instead |
|--------------|---------|
| Duplicate Section 2 in tests | `require("color_math")` (PITFALLS #2) |
| Extract `bridge_client.lua` in Phase 2 | Keep Section 2c in monolith (D-20, D-28) |
| Add `ComponentLua` per module in `plugin.xml` | Single entry + sibling requires (D-38) |
| Harden bridge JSON before module extract | Phase 5 with `bridge_client.lua` |
| Circular requires (`color_math` ↔ `goals`) | `goals` depends on constants only; `color_math` has no goal imports |
| Global exports from modules | `return M` table only (D-24) |

## Function Inventory

### `lua/color_math.lua` ← Section 2 (lines 52–204)

| Symbol | Lines (main) | Notes |
|--------|--------------|-------|
| `CCT_MIN`, `CCT_MAX`, `DUV_MIN`, `DUV_MAX` | 24–29 (§1) | Move here — used by `get_correction` and bridge range checks in entry |
| `GEL_STEPS` | 41–46 (§1) | Move here — used by `gel_hint` |
| `cct_to_xy` | 55–66 | Host tested |
| `xy_to_uvp` | 68–72 | Host tested |
| `uvp_to_xy` | 74–78 | Host tested |
| `apply_duv_correction` | 80–84 | Host tested |
| `get_correction` | 86–95 | Host tested indirectly; keep in color_math |
| `xy_to_rgb` | 97–108 | Host tested |
| `rgb_to_hsb` | 110–123 | Host tested |
| `rate_quality` | 125–130 | Host tested → **color_math** (discretion) |
| `rate_duv` | 132–138 | Host tested → **color_math** |
| `gel_hint` | 151–164 | Host tested |
| ~~`goal_status_str`~~ | 140–149 | → **goals.lua** (D-30) |
| ~~`base64_encode/decode`~~ | 166–201 | **DELETE** (D-33) |

**Estimated size:** ~130 lines module + constants.

### `lua/fixture_db.lua` ← Section 2b (lines 205–379)

| Symbol | Lines (main) | Notes |
|--------|--------------|-------|
| `json_get_str`, `json_get_num`, `json_get_bool` | 214–226 | Internal/private after hardening |
| `json_encode_db_record` | 229–251 | Harden string escape |
| `json_encode_db_array` | 253–257 | Public |
| `json_parse_db_array` | 262–289 | Harden + skip malformed with error |
| `recompute_best_flags` | 296–330 | Public; semantics unchanged |
| `append_fixture_record` | 333–347 | Public; uses `os.date` — **acceptable** at call time in module (no MA3 API) |
| `sort_fixture_records` | 350–358 | Public |
| `find_best_for_fixture` | 361–376 | Public |

**Schema constants (document in module header):** field names `make`, `model`, `kelvin`, `date`, `contributor`, `cct`, `duv`, `cri`, `r9`, `tlci?`, `best_*`.

**Estimated size:** ~200 lines with hardened encoder/parser.

### `lua/goals.lua` ← Section 2 + Section 2c

| Symbol | Source lines | Notes |
|--------|--------------|-------|
| `QUALITY` | 17–22 (§1) | Threshold tables for `rate_*` and `goals_met` |
| `GOAL_MAX`, `GOAL_MIN`, `GOAL_SKIP` | 31–33 (§1) | Goal mode enums |
| `goal_status_str` | 140–149 (§2) | Pure; uses `GOAL_*` |
| `goals_met` | 1213–1223 (§2c) | CCT ±150 K; Duv ± `QUALITY.DUV.acceptable`; TLCI nil handling |
| `CCT_GOAL_TOLERANCE` (optional) | inline 150 | Extract named constant `150` for test clarity |

**Does NOT move:** `show_assessment`, `goals_summary_line` — UI (Section 3).

**Estimated size:** ~60 lines.

### Remains in `lua/SekonicCalibrator.lua`

| Area | Key symbols |
|------|-------------|
| §1 (partial) | `MODE_TARGET`, `MODE_REFERENCE`, `METER_C700`, `METER_C7000`, `STAR` |
| §2c | `_http_request`, `bridge_fetch_measurement`, `bridge_check_status`, `run_bridge_setup`, `show_bridge_status`, `_run_trigger_discovery` |
| §3–6 | All UI, patch, apply, logging, `main` |
| Loader | `load_domain_modules()` at top |

**Bridge note:** `bridge_fetch_measurement` uses `CCT_MIN`, `DUV_MIN`, etc. — entry file references `color_math.CCT_MIN` or local aliases after require.

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| MA3 `require` fails for sibling modules | HIGH | D-23 `dofile` fallback; Phase 7 console verification |
| Test drift during extraction | HIGH | Single `require` source; delete inline copy; run 126+ tests after each commit |
| JSON hardening breaks existing `fixture_log.json` files | MEDIUM | Roundtrip tests; legacy regex fallback per block (D-27); golden fixtures in Phase 3 |
| Circular module dependencies | MEDIUM | Enforce: `fixture_db` → none; `color_math` → none; `goals` → none; entry → all three |
| `append_fixture_record` uses `os.date` in module | LOW | Already pure-stdlib; host tests use fixed dates in entries |
| Removing base64 breaks unknown callers | LOW | Grep confirms no calls since 0530fd2 [VERIFIED: CONCERNS.md] |
| `goals_met` regression undetected | HIGH | D-32 mandatory new tests before sign-off |
| Entry file still references old local function names | MEDIUM | Mechanical grep: no `local function cct_to_xy` in entry after extract |
| Operator-visible parse errors annoy users | LOW | Only on corrupt files; message explains skipped records |

## Open Questions

1. **`rate_quality` / `rate_duv` module placement** — RESOLVED for planning  
   - Decision: **`color_math.lua`** — already host-tested (126+ assertions); UI calls via `color_math.rate_duv` (Claude's discretion in CONTEXT aligns with tests).

2. **`GOAL_*` vs entry-file session constants** — RESOLVED for planning  
   - Decision: **`GOAL_*` + `QUALITY` → `goals.lua`**; **`MODE_*` + `METER_*` → entry Section 1** (D-20); no shared `constants.lua` in Phase 2.

3. **Separate `test_goals.lua` vs extend `test_color_math.lua`** — RESOLVED for planning  
   - Decision: **Extend `test_color_math.lua`** with a `[goals_met]` section in Phase 2 (D-34); unified `tests/run.lua` in Phase 3.

4. **`plugin.xml` Version bump** — RESOLVED for planning  
   - Decision: Keep **`0.5.0`** in `plugin.xml` unless implementation materially changes operator workflow; note modular refactor in Lua header comment only (Claude's discretion).

5. **MA3 native JSON availability** — RESOLVED for planning  
   - Decision: **Do not depend on it** (D-29); hand-rolled hardened encoder in `fixture_db.lua`; re-evaluate only if hardening proves insufficient.

6. **Export style: namespaced vs thin re-exports in entry** — OPEN (low)  
   - Recommendation: **Namespaced** (`color_math.cct_to_xy`) at call sites to make module boundary obvious during review; optional local aliases only where call density is high (e.g. inner loop).

## Primary Recommendation

Execute Phase 2 on **`origin/claude/lighttune-main`** (v0.5.0-replan, ~2046 lines) in this order:

1. **Create domain modules** as pure `return M` files — move function bodies verbatim first (no behavior change).
2. **Add module loader** to entry file top; wire call sites; remove extracted sections and dead base64.
3. **Move `goals_met`** from Section 2c to `goals.lua`; trim Section 3 forward decls; update auto-loop call sites in Section 6.
4. **Harden `fixture_db.lua` JSON** (encode escape + parse skip/errors + internal regex fallback).
5. **Refactor `test_color_math.lua`** — delete lines 57–302 inline copy; `require` modules; remove base64 tests; **add `goals_met` tests** (D-32).
6. **Verify gates:** `lua5.4 test_color_math.lua` → 126+ PASS, 0 FAIL; `grep ComponentLua plugin.xml` → 1; entry file ~1550–1650 lines.

Do **not** rename entry to `main.lua`, add plugin.xml components, or extract Section 2c in this phase. Bridge JSON hardening waits for **`bridge_client.lua`** in Phase 5.

## Sources

### Primary (HIGH confidence)
- `git show origin/claude/lighttune-main:lua/SekonicCalibrator.lua` — section boundaries, function inventory, `goals_met` / forward decls
- `git show origin/claude/lighttune-main:plugin.xml` — single ComponentLua, Version 0.5.0
- `/workspace/test_color_math.lua` — inline duplication pattern, 126+ test sections, no `goals_met`
- `.planning/phases/02-plugin-hardening-test-seams/02-CONTEXT.md` — locked decisions D-19–D-39
- `.planning/ROADMAP.md` — Phase 2 success criteria
- `.planning/REQUIREMENTS.md` — ARCH-01,02,03,05, DB-01
- `.planning/codebase/CONCERNS.md` — monolith, JSON fragility, test duplication, base64 dead code

### Secondary (MEDIUM confidence)
- `.planning/research/ARCHITECTURE.md` — full target layout; Phase 2 = subset
- `.planning/research/PITFALLS.md` — pitfalls #2 (monolith), #3 (JSON), duplicated tests
- `.planning/phases/01-canonical-merge-baseline/01-RESEARCH.md` — document structure template

### Tertiary (LOW confidence)
- MA3 embedded `require("color_math")` without dofile — not validated on physical console [ASSUMED: fallback sufficient until Phase 7]

## Metadata

**Confidence breakdown:**
- Domain split inventory: **HIGH** — direct line mapping from main branch
- JSON hardening approach: **HIGH** — schema-fixed, hand-rolled, matches D-26–D-29
- MA3 module loading: **MEDIUM** — dofile fallback documented; console proof deferred
- Test strategy: **HIGH** — existing 126+ assertions + explicit D-32 goals gap identified

**Research date:** 2026-07-01  
**Valid until:** 2026-07-31

## RESEARCH COMPLETE
