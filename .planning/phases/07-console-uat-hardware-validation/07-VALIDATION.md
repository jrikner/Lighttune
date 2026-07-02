---
phase: 07-console-uat-hardware-validation
type: validation
owner: gsd-planner
requirements:
  - TOP-01
  - UAT-01
  - UAT-02
  - UAT-03
---

# Phase 7 Validation (Nyquist)

This validation is manual-heavy by design. It is the “ship gate” checklist and evidence index for Phase 7.

## Quick commands (terminal)

Run on the macOS host intended for TOP-01.

- Mock bridge (Wave 1):
  - `cd sekonic-bridge`
  - `python3 server.py --mock --port 8765`
  - `curl http://127.0.0.1:8765/status`
  - `curl -X POST http://127.0.0.1:8765/measure`

- Real bridge (Wave 2, hardware required):
  - `cd sekonic-bridge`
  - `python3 server.py --port 8765`
  - `curl http://127.0.0.1:8765/status`
  - `curl -X POST http://127.0.0.1:8765/measure`

## Deterministic LuaSocket check (onPC)

This is the required UAT-02 check.

- Attempt a Remote Measurement from the plugin.
- Interpret the result:
  - **FAIL (stop ship):** error contains `luasocket_unavailable`
  - **PASS (LuaSocket present):** error is a normal connection problem (e.g. connection refused) when bridge is down, and remote succeeds once the bridge is running

Capture a screenshot proving which case occurred.

## Evidence checklist (what to produce)

Create one bundle per run:

- `.planning/phases/07-console-uat-hardware-validation/evidence/<run_id>/`

### Bundle metadata (required)

- `env.md`
  - onPC version, macOS version, host model
  - `bridge_ip`/`bridge_port` (must be `127.0.0.1:8765` for TOP-01)
  - fixture group ID + fixture make/model used for UAT-01 timing run

### Wave 1 (no hardware required)

- `bridge_status_mock.txt`
- `bridge_measure_mock.txt` (recommended)
- `screens/remote_offer_dialog.png`
- `screens/measurement_received_mock.png`
- `screens/bridge_error_connection_refused.png`
- `screens/luasocket_check_success.png` OR `screens/luasocket_check_luasocket_unavailable.png`
- `notes_wave1.md`

### Wave 2 (hardware required)

- `bridge_status_real.txt`
- `bridge_measure_real.txt`
- `bridge.log` (or `bridge_log.txt`)
- `phase5_deferred_tests.md`
- `screens/bridge_status.png`
- `screens/remote_offer_dialog_real.png`
- `screens/measurement_received_real.png`
- `screens/bridge_error_real.png`
- `screens/auto_loop_confirm.png`
- `screens/auto_loop_stuck_after_3.png` (if achievable)
- `screens/bridge_setup_steps.png` (if wizard exists in build)
- `video/uat01_single_group_e2e.mp4`
- `screens/session_summary_or_group_done_real.png`
- `timing.csv`
- `notes_wave2.md`

## Requirement verification map (Phase 7 ship gate)

| Requirement | Pass condition | Evidence (minimum) |
|------------|----------------|--------------------|
| TOP-01 | UAT executed on macOS onPC with bridge on `127.0.0.1:8765` | `env.md`, `bridge_status_real.txt` |
| UAT-02 | LuaSocket TCP works on the target onPC build | `screens/bridge_error_connection_refused.png` or `screens/measurement_received_*` showing no `luasocket_unavailable` |
| UAT-03 | Operator triggers remote measure; sees metrics in UI (CCT/Duv/CRI/R9/TLCI when present) | `screens/measurement_received_real.png`, `video/uat01_single_group_e2e.mp4` |
| UAT-01 | End-to-end single-group calibration run completed on TOP-01 topology with timing captured | `video/uat01_single_group_e2e.mp4`, `timing.csv`, `screens/session_summary_or_group_done_real.png` |

