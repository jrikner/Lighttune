# Phase 2: Plugin Hardening & Test Seams - Context

**Gathered:** 2026-07-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Refactor the v0.5.0-replan monolith on `claude/lighttune-main` into **host-testable domain modules** while keeping a **single deployable MA3 plugin** (`plugin.xml` → `lua/SekonicCalibrator.lua`). Eliminate duplicated color math in `test_color_math.lua`, harden fixture DB JSON handling, and isolate pure goals/assessment logic — without splitting UI, bridge HTTP client, or calibration orchestration (those stay in the monolith until later phases).

**In scope:** ARCH-01, ARCH-02, ARCH-03, ARCH-05, DB-01  
**Out of scope:** `bridge_client.lua` extract (ARCH-04 → Phase 5), bridge JSON hardening (Phase 5), CI workflow (Phase 3), UI module split (Phase 6), `main.lua` rename unless `require` fails on host.

</domain>

<decisions>
## Implementation Decisions

### Module split depth (D-19)
- **D-19:** Extract the **domain trio** — minimum set for host testing and ARCH requirements:
  1. `lua/color_math.lua` — Section 2 pure functions (CCT/xy/Duv, correction, gel hints, quality rating helpers used by tests)
  2. `lua/fixture_db.lua` — Section 2b JSON helpers, `recompute_best_flags`, `append_fixture_record`, schema constants
  3. `lua/goals.lua` — `goals_met`, `goal_status_str`, and goal-mode constants (`GOAL_MIN`, `GOAL_MAX`, `GOAL_SKIP`) plus `QUALITY` thresholds they depend on
- **D-20:** Do **not** extract in Phase 2: `bridge_client` (Section 2c), `config.lua`, `patch_api` (Section 3b), `fixture_apply` (Section 4), UI (Section 3), `calibration` orchestration (Section 6), or `constants.lua` as a separate file — session/meter mode constants remain in the entry file unless pulled into `goals.lua`/`color_math.lua` as needed for module purity.
- **D-21:** Target line reduction: entry file shrinks by ~400–500 lines (Sections 2, 2b core, goals); remaining ~1,500+ lines stay until Phase 5–6.

### Entry point & module loading (D-22)
- **D-22:** Keep **`lua/SekonicCalibrator.lua` as the sole `ComponentLua` entry** — no `main.lua` rename in Phase 2; avoids operator/docs churn and matches existing `plugin.xml`.
- **D-23:** Module loader pattern at top of entry file:
  1. Resolve plugin directory via `GetPath(Enums.PathType.PluginLibrary)` (same as `load_config()`).
  2. Prepend `plugin_dir .. "/lua/?.lua"` to `package.path`.
  3. `local color_math = require("color_math")` (and likewise for `fixture_db`, `goals`).
  4. **Fallback:** if `require` fails (host tests or MA3 path quirks), `dofile(plugin_dir .. "/lua/color_math.lua")` with identical return-table contract.
- **D-24:** Each extracted module returns a table (`return M`); no MA3 API calls at module top level. Entry file re-exports or calls `M.function` — no global pollution of `_G`.
- **D-25:** Host test runner uses `package.path` pointing at `lua/` (repo-relative) so `require("color_math")` works without MA3; **no duplicated inline copies** in `test_color_math.lua` after Phase 2.

### JSON hardening scope (D-26)
- **D-26:** **Incremental harden fixture DB JSON only** (ARCH-02, DB-01) — replace fragile regex-only paths with structured encode/decode for the known flat-array schema:
  - Escape `"`, `\`, and control chars in string fields (`make`, `model`, `contributor`, `date`)
  - Reject or skip malformed records with logged/visible error instead of silent `{}`
  - Preserve append-only array shape and `best_*` flag semantics unchanged
- **D-27:** Keep regex-based field extractors only as **internal fallback** inside `fixture_db.lua` if a record block fails structured parse — do not expose two public APIs.
- **D-28:** **Defer bridge response JSON hardening** (Section 2c `_http_request` / `bridge_fetch_measurement` regex parses) to **Phase 5** when `bridge_client.lua` is extracted (ARCH-04). Phase 2 may touch bridge code only for `require` wiring if goals/constants move — not for JSON refactor.
- **D-29:** No external JSON library dependency — MA3 may lack one; hand-rolled encoder with explicit schema is acceptable if hardened.

### Goals & assessment isolation (D-30)
- **D-30:** **ARCH-03 satisfied by pure function extraction** to `goals.lua`:
  - `goals_met(measured, goals)` — auto-loop gate (Phase 5 depends on this)
  - `goal_status_str(measured_val, goal)` — assessment strings
  - Supporting constants: `QUALITY`, `GOAL_*` modes
- **D-31:** **Assessment UI stays in monolith** — `show_assessment`, `rate_quality`, `rate_duv`, MessageBox flows remain in `SekonicCalibrator.lua` Section 3; they **call into** `goals` and `color_math` but are not extracted in Phase 2.
- **D-32:** Add host tests for `goals_met` edge cases (TLCI nil, GOAL_SKIP, CCT ±150 K boundary, Duv tolerance) in Phase 2 or Phase 3 — at minimum preserve existing 126+ color-math assertions and add goals coverage before Phase 2 sign-off.

### Cleanup & test layout (D-33)
- **D-33:** **Remove dead code:** `base64_encode`, `base64_decode`, and `B64_*` lookup tables (~35 lines) — unused since community upload removal (0530fd2).
- **D-34:** **Test file location for Phase 2:** keep `test_color_math.lua` at **repo root** — refactor to `require` shared modules; rename optional in Phase 3 when CI adds `tests/run.lua`.
- **D-35:** **`data/measurements/`:** leave untouched — directory is reserved/unused; no create/delete in Phase 2 unless `.gitignore` already covers it.
- **D-36:** Remove stale header comments referencing community upload if still present after extraction.
- **D-37:** Phase 2 execution target: **`claude/lighttune-main`** (post Phase 1 baseline `91b322c` or later); planning artifacts stay on `cursor/install-gsd-core-342d`.

### Single-plugin artifact (D-38, ARCH-05)
- **D-38:** `plugin.xml` continues to declare **one** `ComponentLua` → `lua/SekonicCalibrator.lua`. New files under `lua/` are sibling modules, not additional plugin components.
- **D-39:** Calibration intelligence (color math, goals, fixture DB, future bridge client) remains **on-console** — no logic moves to Pi in this phase.

### Claude's Discretion
- Exact split of `rate_quality` / `rate_duv` between `color_math.lua` vs entry file (prefer `color_math` if host-tested).
- Whether `GOAL_*` / `MODE_*` / `METER_*` constants live in `goals.lua` or a tiny shared snippet — must not create circular requires.
- Host test file naming (`test_goals.lua` vs extended `test_color_math.lua`) — defer unified runner to Phase 3.
- `plugin.xml` Version bump (stay `0.5.0` vs patch `0.5.1-replan`) — note in README/Lua header only if semver unchanged.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & roadmap
- `.planning/ROADMAP.md` — Phase 2 goal, success criteria, ARCH-01/02/03/05, DB-01
- `.planning/REQUIREMENTS.md` — module extraction requirements; ARCH-04 deferred to Phase 5
- `.planning/PROJECT.md` — single-plugin + thin bridge; shared test strategy

### Phase 1 baseline (prerequisite)
- `.planning/phases/01-canonical-merge-baseline/01-CONTEXT.md` — cherry-pick decisions, config path
- `.planning/phases/01-canonical-merge-baseline/01-CHERRY-PICK-MANIFEST.md` — main at v0.5.0-replan
- `origin/claude/lighttune-main` — execution target (~2,046 lines, Section 2/2b/2c layout)

### Codebase intelligence
- `.planning/codebase/CONCERNS.md` — monolith, JSON fragility, test duplication, dead base64
- `.planning/research/ARCHITECTURE.md` — full target layout (Phase 2 implements **subset**: domain trio only)
- `.planning/research/PITFALLS.md` — Pitfall: duplicated test logic; regex JSON breaks on quotes
- `.planning/research/STACK.md` — host `lua5.4` tests, no JSON library on console

### Verification baseline
- `test_color_math.lua` — 126 passed / 0 failed on main after Phase 1 Wave 3
- `lua/SekonicCalibrator.lua` sections: 1 constants, 2 color math, 2b fixture DB, 2c bridge, 3 UI, 3b patch, 4 apply, 5 logging, 6 main

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets (main post–Phase 1)
- `lua/SekonicCalibrator.lua` v0.5.0-replan — monolith with bridge Section 2c embedded
- `test_color_math.lua` — ~575 lines, ~240 lines duplicate Sections 2/2b inline
- `data/fixture_log.json` schema documented in Section 2b header (append-only, best_* flags)
- `load_config()` at Section 5 — plugin root `config.json`; DB at `data/fixture_log.json`

### Established Patterns
- Forward declarations for bridge functions (`goals_met`, `_http_request`) before Section 2c assignment — preserve when slimming entry file
- Pure functions in Sections 2/2b already MA3-API-free — safe first extraction candidates
- Host tests run: `lua5.4 test_color_math.lua` from repo root

### Integration Points
- Phase 3 CI will consume shared modules — Phase 2 must make `require("color_math")` work from repo root
- Phase 5 auto-loop calls `goals_met()` — must live in testable `goals.lua` before HTTP integration
- Phase 6 may split UI — do not preempt with partial ui/ folder in Phase 2

</code_context>

<specifics>
## Specific Ideas

- User selected **All** five gray areas for discussion — locked defaults below align with ROADMAP “minimum for host testing” and ARCH-05 single-plugin constraint.
- Prefer **pragmatic trio extract** over research doc’s full multi-file layout — reduces MA3 `require` risk while eliminating test duplication.
- Bridge JSON and `bridge_client.lua` intentionally deferred — Phase 2 hardening focuses where DB corruption hurts operators (fixture names with quotes).

</specifics>

<deferred>
## Deferred Ideas

- `bridge_client.lua` + bridge JSON parser — **Phase 5** (ARCH-04)
- `config.lua`, `patch_api.lua`, `fixture_apply.lua`, `ui/*`, `calibration.lua` — **Phase 5–6**
- `main.lua` entry rename — only if MA3 requires it after console `require` verification (**Phase 7** UAT)
- `tests/run.lua` unified runner + golden fixtures — **Phase 3**
- Full structured JSON library or MA3 native JSON — evaluate if hand-rolled hardening insufficient

</deferred>

---

*Phase: 2-Plugin Hardening & Test Seams*
*Context gathered: 2026-07-01*
