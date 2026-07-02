---
phase: 05-ma3-http-integration
plan: 02
subsystem: ui
tags: [lua, bridge, error-ux, c7000-gate]

requires:
  - phase: 05-ma3-http-integration
    provides: bridge_client module
provides:
  - Monolith HTTP delegation via bridge_client
  - format_bridge_error operator strings
  - C-7000 remote offer gate
  - Enhanced Bridge Status (auth_required, last_error)
affects: [05-03]

key-files:
  modified: [lua/SekonicCalibrator.lua]

requirements-completed: [MTR-03, MTR-04, MTR-06]

duration: 20min
completed: 2026-07-02
status: complete
---

# Phase 5 Plan 02 Summary

**Wired SekonicCalibrator to bridge_client, enriched failure UX, gated remote on C-7000 session meter, and enhanced Bridge Status.**

## Accomplishments
- Removed inline `_http_request` / socket code from monolith; all HTTP via bridge_client
- Added `format_bridge_error` mapping kinds to operator-facing strings (D-83)
- Preserved Retry Remote / Enter Manually / Cancel on measure and auto-loop errors (D-82)
- Remote offer gated on `goals.meter == METER_C7000` when bridge_ip set (D-91)
- Bridge Status shows auth line and last_error when reachable (D-96)
- Setup wizard and trigger discovery use bridge_client route helpers (D-95, D-98)

## Self-Check: PASSED
- No `socket.tcp` in SekonicCalibrator.lua
- pytest 9 passed; lua regression green
