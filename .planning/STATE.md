---
gsd_state_version: 1.0
milestone: v0.4
milestone_name: milestone
current_phase: 6
current_phase_name: Operator UX, Docs & Show Readiness
status: ready_to_plan
stopped_at: Phase 6 planning — macOS TOP-01 priority
last_updated: "2026-07-02T23:30:00.000Z"
last_activity: 2026-07-02
last_activity_desc: TOP-01 macOS local bridge elevated to primary topology on roadmap
progress:
  total_phases: 7
  completed_phases: 5
  total_plans: 15
  completed_plans: 15
  percent: 71
---

# Project State

## Project Reference

**Core value:** FOH calibration in under five minutes with broadcast-grade targets.
**Current focus:** Phase 6 — Operator UX, Docs & Show Readiness (**macOS onPC runbook is top priority**)

## Current Position

Phase: 6 of 7 (Operator UX, Docs & Show Readiness)
Plan: 0 (not yet planned)
Status: Ready to plan (`/gsd-plan-phase 6`)
Last activity: 2026-07-02 — Topology decision: macOS local bridge primary (TOP-01)

Progress: [█████████░] 71%

## Locked decision — macOS primary (TOP-01, 2026-07-02)

- **Default deployment:** Mac laptop runs GrandMA3 onPC + `sekonic-bridge` on `127.0.0.1`; C-7000 USB on same Mac
- **Pi optional:** only when console and meter are on different machines (stage split)
- **Phase 6 docs:** macOS runbook before Pi VLAN runbook
- **Phase 7 UAT:** sign off on macOS path first; Pi secondary
- **Phase 5 UAT:** deferred; resume with macOS localhost when ready (`/gsd-verify-work 5`)

## Phase 5 execution summary

- `lua/bridge_client.lua` extracted (ARCH-04); monolith delegates all HTTP
- C-7000 remote gate, enriched errors, Bridge Status auth/last_error (MTR-03/04/06)
- Auto-loop verified unchanged (MTR-05); `tests/test_bridge_client.lua` added (161 PASS)
- Human MA3 UAT pending: `/gsd-verify-work 5`

## Session Continuity

Resume file: `/gsd-plan-phase 6`
