# Phase 1: Canonical Merge & Baseline - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-01
**Phase:** 1-Canonical Merge & Baseline
**Areas discussed:** Canonical Sekonic snapshot, Cherry-pick scope, Version label at baseline, README truth scope, Integration branch strategy

---

## Canonical Sekonic snapshot

| Option | Description | Selected |
|--------|-------------|----------|
| Research branch | `sekonic-remote-api-research-HdMTl` with skreader SDK (5cc8bf8) | ✓ |
| Experimental branch | `Lighttune-experimental` PR #2 merge | |
| Hybrid | Research base + manual experimental fixes | |

**User's choice:** Research branch — "the one with skreader"
**Notes:** skreader bulk protocol integration is the deciding factor; experimental branch lacks 5cc8bf8 and diverges in five files.

---

## Cherry-pick scope

| Option | Description | Selected |
|--------|-------------|----------|
| Full Sekonic stack | All 6 commits: bridge tree + v0.5 Lua HTTP client | ✓ |
| Plugin-first subset | v0.5 Lua + config only; defer bridge to Phase 4 | |
| Curated picks | Selective commits (e.g. skip trigger discovery) | |

**User's choice:** Full
**Notes:** Entire `sekonic-bridge/` and v0.5 plugin networking land on main in Phase 1.

---

## Version label at baseline

| Option | Description | Selected |
|--------|-------------|----------|
| v0.5 | Match existing Sekonic branch header | |
| v0.5.0-replan | Interim replan milestone label | ✓ |
| v1.0.0 | Declare production baseline now | |

**User's choice:** v0.5.0-replan
**Notes:** Signals brownfield replan without claiming UAT-complete v1 ship.

---

## README truth scope

| Option | Description | Selected |
|--------|-------------|----------|
| Full honesty pass | Remove all false claims; document bridge + Patch API truth | ✓ |
| Minimal delta | Fix only provably false main-branch claims | |
| Split README | Operator vs integrator sections with different depth | |

**User's choice:** Full honesty
**Notes:** Community upload, curl/unzip console requirements, on-disk GDTF claims must go; bridge workflow and config path must be accurate.

---

## Integration branch strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Feature branch → PR | Reviewable merge to main | |
| Direct to main | Cherry-picks land on `claude/lighttune-main` immediately | ✓ |
| Long-lived integration branch | Keep main at v0.4 until UAT | |

**User's choice:** Direct to main — "everything until we have a working base"
**Notes:** Optimize for clone-from-main working tree; manifest provides audit trail instead of PR gate.

---

## Claude's Discretion

- `plugin.xml` Version attribute format if non-semver rejected by MA3
- Cherry-pick manifest file path (recommended under phase directory)
- Commit ordering on main (cherry-picks vs doc alignment)

## Deferred Ideas

- HID wizard collapse and bulk module rename — Phase 4–6
- Lua module extraction — Phase 2
- Bridge auth — Phase 4
- Experimental-only driver refactors — only if cherry-pick conflicts
