# Phase 7: Console UAT & Hardware Validation - Context

**Gathered:** 2026-07-02
**Status:** Ready for planning
**Source:** ROADMAP.md + REQUIREMENTS.md + Phase 5 UAT script + Phase 6 manual-only validation notes (no discuss-phase run)

<domain>
## Phase Boundary

Phase 7 is the **ship gate** for Lighttune v1. It validates the full operator workflow **end-to-end on real GrandMA3 onPC** with real bridge networking and (ideally) real C-7000 hardware.

**Primary topology (TOP-01):** a single macOS laptop runs:
- GrandMA3 onPC (v1.6+)
- `sekonic-bridge` on `127.0.0.1:8765`
- Sekonic C-7000 connected via USB to the same Mac

**Secondary topology:** stage-split Pi bridge on show LAN (optional smoke test or doc-only).

**In scope:**
- A reproducible **UAT checklist** (commands + expected UI states) that proves UAT-01/02/03 + TOP-01.
- Evidence capture conventions: what screenshots/logs to save, what values to record (time-to-complete, key measurement values).
- Validate that the plugin’s LuaSocket TCP HTTP client actually works on the production onPC build (UAT-02).
- Validate remote measurement UX and returned values shown to operator (UAT-03).
- Validate a full single-group calibration can complete in under 5 minutes (or document the blocker and acceptance override path) (UAT-01).

**Out of scope:**
- New feature work (no more modularization/refactors).
- Closed-loop correction algorithm redesign (CAL-07). If auto-loop convergence is poor, Phase 7 records evidence and decides whether a corrective follow-up phase is needed; it does not silently change the algorithm.
- Security hardening beyond existing `bridge_api_key` behavior.

</domain>

<decisions>
## Implementation Decisions

### UAT-first, macOS-first (TOP-01)
- **D-201:** Phase 7 UAT runs on **macOS onPC + localhost bridge** first; Pi stage-split is secondary (TOP-01, ROADMAP).
- **D-202:** UAT must verify the published Phase 6 macOS runbook steps actually work on a clean-ish Mac (venv, libusb, server start, curl `/status`).

### Evidence and acceptance
- **D-203:** Record objective evidence for each requirement:
  - command outputs (curl `/status`, optional `/measure` in mock mode),
  - visible plugin UI states (Bridge Status, measurement values received, assessment screen),
  - time-to-complete for one group.
- **D-204:** If metric goals are not met due to fixture limits, operator can explicitly **accept** the current result; UAT must capture that this was an acceptance override rather than a pass.

### Compatibility gates
- **D-205:** Validate `require("socket")`/LuaSocket TCP availability on the exact onPC build used for production (UAT-02). If it fails, Phase 7 stops and creates a follow-up plan (compat fallback decision) rather than shipping.

### Relationship to Phase 5 UAT
- **D-206:** Phase 5 `/gsd-verify-work 5` checklist is subsumed into Phase 7 and should be executed as part of the Phase 7 run (Bridge Status, remote offer gate, remote flow, error flow, auto-loop confirm/stuck).

</decisions>

<phase_requirements>
## Phase Requirements (ship gates)

| ID | Requirement |
|----|------------|
| TOP-01 | macOS + onPC + local bridge `127.0.0.1:8765` is the default UAT environment |
| UAT-01 | End-to-end validated on macOS onPC 1.6+ with localhost bridge + C-7000 USB |
| UAT-02 | `require("socket")` / LuaSocket TCP verified on target onPC build |
| UAT-03 | Operator triggers remote measure; sees CCT/Duv/CRI/R9/TLCI in plugin UI |

</phase_requirements>

<canonical_refs>
## Canonical References

### Requirements and success criteria
- `.planning/ROADMAP.md` — Phase 7 goal + success criteria
- `.planning/REQUIREMENTS.md` — UAT-01/02/03 and TOP-01 wording
- `.planning/STATE.md` — macOS-first ship gate note

### Prior UAT script and deferrals
- `.planning/phases/05-ma3-http-integration/05-UAT.md` — detailed UI test cases for bridge integration
- `.planning/phases/05-ma3-http-integration/05-VERIFICATION.md` — manual UAT deferred to Phase 7
- `.planning/phases/06-operator-ux-docs-show-readiness/06-03-PLAN.md` — “ready for Phase 7 UAT” constraint
- `.planning/phases/06-operator-ux-docs-show-readiness/06-VALIDATION.md` — manual-only verifications mapped to Phase 7

### Product docs (runbook being validated)
- `README.md` — macOS onPC + local bridge setup and operator workflow
- `sekonic-bridge/README.md` — macOS primary setup + Pi secondary
- `data/config.json.example` — expected localhost config

</canonical_refs>

<specifics>
## Specific UAT Test Script Outline

Phase 7 should produce an executable checklist that includes:

1. **Bridge bring-up (macOS)**
   - Start `sekonic-bridge` (real C-7000 if available; otherwise mock for networking verification)
   - `curl http://127.0.0.1:8765/status` returns JSON with `"status":"ok"` (or documented equivalent)

2. **Plugin Bridge Status**
   - Main menu → Bridge Status shows reachable bridge and flags (auth line + last_error when present)

3. **Remote offer gate**
   - C-7000 selected → remote option offered when `bridge_ip` set
   - C-700/C-800 selected → remote option not offered (manual only)

4. **Remote measurement flow**
   - Trigger remote measure, confirm received values, accept

5. **Calibration loop**
   - One group complete in <5 minutes (measure→assess→apply→(optional auto-loop)→accept)

6. **Error path**
   - Demonstrate at least one failure mode (e.g., wrong api key or bridge stopped) and confirm Retry/Manual/Cancel UX

</specifics>

<deferred>
## Deferred Ideas

- Closed-loop correction redesign (CAL-07)
- Stronger auth beyond shared key
- Pi stage-split is optional (document-only is acceptable if no access)

</deferred>

---

*Phase: 07-console-uat-hardware-validation*
*Context gathered: 2026-07-02 — synthesized for planning*
