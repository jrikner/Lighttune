---
status: testing
phase: 05-ma3-http-integration
source:
  - 05-01-SUMMARY.md
  - 05-02-SUMMARY.md
  - 05-03-SUMMARY.md
  - 05-VERIFICATION.md
started: 2026-07-02T22:30:00Z
updated: 2026-07-02T23:00:00Z
paused: true
---

## Current Test

number: 1
name: Bridge Status — auth and last error
expected: |
  On GrandMA3 with bridge_ip configured and Pi bridge running:
  Main menu → Bridge Status shows reachable bridge with Meter, Status, Device, Protocol, Trigger lines.
  An Auth line appears (Required with key configured, Required — add bridge_api_key, or Not required).
  If the bridge has a recent error, a Last err line shows the message.
awaiting: deferred — user will resume later

## Tests

### 1. Bridge Status — auth and last error
expected: Main menu → Bridge Status shows auth line and last_error when bridge is reachable (D-96).
result: pending

### 2. C-7000 remote offer gate
expected: With bridge_ip set and session meter C-7000, first measurement shows Remote Measurement / Enter Manually / Cancel. With C-700/C-800 session, remote dialog is skipped — manual entry only (D-91).
result: pending

### 3. Remote measure — first attempt flow
expected: C-7000 session + bridge_ip → choose Remote Measurement → values return → Accept / Re-measure / Enter Manually confirmation. Accept proceeds with bridge values (MTR-03, D-87).
result: pending

### 4. Bridge error — enriched UX
expected: On bridge failure (e.g. wrong bridge_api_key or unplugged meter), error dialog shows readable message (auth hint for 401, connection/timeout text). Buttons: Retry Remote, Enter Manually, Cancel (MTR-04, D-82).
result: pending

### 5. Auto-loop — per-cycle confirm
expected: After first accepted remote measure, attempt 2+ auto-triggers bridge. Each auto-measurement shows Accept / Enter Manually / Cancel before assessment — no silent auto-accept (MTR-05, D-88).
result: pending

### 6. Auto-loop — stuck after 3 attempts
expected: After 3 measurement cycles without goals met, dialog shows Accept & Move On / Try Again / Skip Group. Try Again resets cycle counter only (D-89).
result: pending

### 7. Bridge Setup wizard preserved
expected: Bridge Status → Run Setup (or main menu Bridge Setup): Step 1 discover → Step 2 capture test measure → Step 3 optional learn_trigger. Status flags update after completion (D-75, MTR-06).
result: pending

## Summary

total: 7
passed: 0
issues: 0
pending: 7
skipped: 0
blocked: 0

## Gaps

[none yet]
