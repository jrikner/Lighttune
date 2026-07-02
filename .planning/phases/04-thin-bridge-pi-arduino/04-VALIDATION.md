---
phase: 4
slug: thin-bridge-pi-arduino
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-02
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Host framework** | Lua 5.4 — `tests/run.lua` (regression guard) |
| **Bridge framework** | pytest + Starlette TestClient (mock meter) |
| **Auth tests** | `tests/test_bridge_auth.py` |
| **Setup smoke** | `tests/test_bridge_setup_routes.py` (optional, mock mode) |
| **Config files** | `sekonic-bridge/bridge_config.json.example`, `data/config.json.example` |
| **Quick bridge command** | `pytest tests/test_bridge_routes.py tests/test_bridge_auth.py -v` |
| **Estimated runtime** | ~20 seconds |

---

## Sampling Rate

- **After every task commit:** Run affected pytest subset; run `lua5.4 tests/run.lua` if plugin touched
- **After Wave 1:** pytest core trio; grep no meter_c7000_hid
- **After Wave 2:** pytest core + auth
- **Before `/gsd-verify-work`:** Full gates below + manual plugin wizard checklist (D-75)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Automated Command | Status |
|---------|------|------|-------------|-------------------|--------|
| 04-01-01 | 01 | 1 | MTR-02 | `test -f sekonic-bridge/meter_backend.py` | ⬜ pending |
| 04-01-02 | 01 | 1 | MTR-02 | bulk rename grep + no hid file | ⬜ pending |
| 04-01-03 | 01 | 1 | MTR-02 | `pytest tests/test_bridge_routes.py -q` | ⬜ pending |
| 04-02-01 | 02 | 2 | MTR-08 | auth in server.py + bridge_config example | ⬜ pending |
| 04-02-02 | 02 | 2 | MTR-08 | plugin X-Bridge-Key grep | ⬜ pending |
| 04-02-03 | 02 | 2 | MTR-08 | `pytest tests/test_bridge_auth.py -q` | ⬜ pending |
| 04-03-01 | 03 | 3 | MTR-01 | no color_math/goals in sekonic-bridge | ⬜ pending |
| 04-03-02 | 03 | 3 | MTR-07 | `pytest tests/test_bridge_setup_routes.py -q` | ⬜ pending |
| 04-03-03 | 03 | 3 | MTR-01–08 | validation sign-off | ⬜ pending |

---

## Wave 0 Requirements

- [ ] Python 3.12 venv with pytest (from Phase 3)
- [ ] `lua5.4` for host regression
- [ ] Phase 3 CI green baseline

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| In-plugin Bridge Setup wizard | D-75, MTR-06 partial | No MA3 in CI | Main menu → Bridge Setup → discover → capture → status flags true |
| Bridge Status screen | D-75 | Plugin UI | Main menu → Bridge Status → connected + setup flags display |
| Real C-7000 USB on Pi | MTR-02 hardware | No USB in CI | Phase 7 UAT; Wave 3 uses mock only |

---

## Phase 4 Sign-Off Gates (post-execution)

| # | Gate | Requirement |
|---|------|-------------|
| 1 | `meter_c7000_bulk.py` exists; `meter_c7000_hid.py` removed | MTR-02 |
| 2 | `pytest tests/test_bridge_routes.py tests/test_bridge_auth.py` all pass | MTR-08, TST-02 |
| 3 | `lua5.4 tests/run.lua` — 139+ PASS, 0 FAIL | regression |
| 4 | No calibration logic in `sekonic-bridge/` | MTR-01 |
| 5 | Mock `/measure` returns progression fields | MTR-07 |
| 6 | Plugin wizard manual checklist passed | D-75 |

---

## Validation Sign-Off

- [ ] All tasks have automated verify or manual gate
- [ ] MTR-01, MTR-02, MTR-07, MTR-08 referenced
- [ ] In-plugin setup preserved (D-75)

**Approval:** pending execution
