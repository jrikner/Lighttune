# Phase 2: Plugin Hardening & Test Seams - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-01
**Phase:** 2-Plugin Hardening & Test Seams
**Areas discussed:** Module split depth, Entry point & loading, JSON hardening scope, Goals/assessment isolation, Cleanup & test layout

**User selection:** **All** — discuss and lock every gray area (defaults applied where per-option answers were not given).

---

## 1. Module split depth

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal pair | `color_math.lua` + `fixture_db.lua` only | |
| Domain trio | + `goals.lua` for auto-loop test seam | ✓ |
| Full research layout | + bridge_client, config, ui/*, calibration, main.lua | |

**User's choice:** All areas — default **domain trio** (aligns with ROADMAP minimum + Phase 5 `goals_met` dependency)
**Notes:** Research ARCHITECTURE.md proposes 10+ files; Phase 2 intentionally extracts only what host tests require. UI, bridge, patch, apply stay in monolith.

---

## 2. Entry point & module loading

| Option | Description | Selected |
|--------|-------------|----------|
| Keep SekonicCalibrator.lua | Single ComponentLua entry; add lua/*.lua siblings | ✓ |
| Rename to main.lua | Match research layout; update plugin.xml | |
| require only | Standard package.path prepend | |
| require + dofile fallback | Host tests + MA3 path safety | ✓ |

**User's choice:** All areas — keep entry filename; **require with dofile fallback**
**Notes:** Console verification of `require` deferred to Phase 7 UAT; fallback unblocks host tests immediately.

---

## 3. JSON hardening scope

| Option | Description | Selected |
|--------|-------------|----------|
| Incremental (fixture DB) | Harden encode/escape + parse errors for fixture_log schema | ✓ |
| Full structured schema | Replace all regex JSON including bridge responses | |
| Defer all hardening | Extract modules only; keep regex | |

**User's choice:** All areas — **fixture DB only** in Phase 2
**Notes:** Bridge `_http_request` body parsing (Section 2c) deferred to Phase 5 with `bridge_client.lua`. DB corruption from `"` in make/model is higher operator risk than bridge key reordering.

---

## 4. Goals & assessment isolation (ARCH-03)

| Option | Description | Selected |
|--------|-------------|----------|
| Pure functions only | `goals_met`, `goal_status_str` → goals.lua; UI stays put | ✓ |
| Full assessment module | Extract show_assessment + rating UI | |
| Defer ARCH-03 | Leave goals in Section 2c until Phase 5 | |

**User's choice:** All areas — **pure functions only**
**Notes:** `rate_quality` / `rate_duv` may move to `color_math.lua` at implementer discretion. MessageBox assessment screens remain in Section 3.

---

## 5. Cleanup & test layout

| Option | Description | Selected |
|--------|-------------|----------|
| Remove dead base64 | Delete unused encode/decode helpers | ✓ |
| Keep test at repo root | Refactor test_color_math.lua to require modules | ✓ |
| Move to tests/ | Defer until Phase 3 CI runner | |
| Touch data/measurements/ | Create or wire reserved dir | |
| Leave data/measurements/ | No change | ✓ |

**User's choice:** All areas — remove base64; root-level tests; ignore measurements dir
**Notes:** Phase 3 may add `tests/run.lua` and relocate files; Phase 2 priority is deduplication + 126+ assertion preservation.

---

## Claude's Discretion

- Split of rating helpers between color_math vs entry file
- Constants packaging (GOAL_*, MODE_*, METER_*) without circular requires
- Version bump policy after refactor
- Whether to add `test_goals.lua` in Phase 2 vs Phase 3

## Deferred Ideas

- bridge_client.lua — Phase 5
- main.lua rename — only if require fails on console
- Unified tests/ directory — Phase 3
- Bridge JSON hardening — Phase 5
