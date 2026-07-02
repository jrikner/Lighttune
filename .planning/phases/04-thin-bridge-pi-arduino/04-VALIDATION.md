---
phase: 4
slug: thin-bridge-pi-arduino
status: signed_off
nyquist_compliant: true
wave_0_complete: true
created: 2026-07-02
executed: 2026-07-02
---

# Phase 4 — Validation Strategy

> Per-phase validation contract — signed off after execution on claude/lighttune-main @ a5eb6d1.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Host framework** | Lua 5.4 — `tests/run.lua` (regression guard) |
| **Bridge framework** | pytest + Starlette TestClient (mock meter) |
| **Auth tests** | `tests/test_bridge_auth.py` |
| **Setup smoke** | `tests/test_bridge_setup_routes.py` (mock mode) |
| **Config files** | `sekonic-bridge/bridge_config.json.example`, `data/config.json.example` |
| **Quick bridge command** | `pytest tests/test_bridge_routes.py tests/test_bridge_auth.py -v` |
| **Estimated runtime** | ~20 seconds |

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Automated Command | Status |
|---------|------|------|-------------|-------------------|--------|
| 04-01-01 | 01 | 1 | MTR-02 | `test -f sekonic-bridge/meter_backend.py` | ✅ pass |
| 04-01-02 | 01 | 1 | MTR-02 | bulk rename grep + no hid file | ✅ pass |
| 04-01-03 | 01 | 1 | MTR-02 | `pytest tests/test_bridge_routes.py -q` | ✅ 3 passed |
| 04-02-01 | 02 | 2 | MTR-08 | auth in server.py + bridge_config example | ✅ pass |
| 04-02-02 | 02 | 2 | MTR-08 | plugin X-Bridge-Key grep | ✅ pass |
| 04-02-03 | 02 | 2 | MTR-08 | `pytest tests/test_bridge_auth.py -q` | ✅ 3 passed |
| 04-03-01 | 03 | 3 | MTR-01 | no color_math/goals in sekonic-bridge | ✅ pass |
| 04-03-02 | 03 | 3 | MTR-07 | `pytest tests/test_bridge_setup_routes.py -q` | ✅ 3 passed |
| 04-03-03 | 03 | 3 | MTR-01–08 | validation sign-off | ✅ pass |

---

## Wave 0 Requirements

- [x] Python 3.12 venv with pytest (from Phase 3)
- [x] `lua5.4` for host regression
- [x] Phase 3 CI green baseline

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| In-plugin Bridge Setup wizard | D-75, MTR-06 partial | No MA3 in CI | Main menu → Bridge Setup → discover → capture → status flags true |
| Bridge Status screen | D-75 | Plugin UI | Main menu → Bridge Status → connected + setup flags display |
| Real C-7000 USB on Pi | MTR-02 hardware | No USB in CI | Phase 7 UAT; Wave 3 uses mock only |

---

## Phase 4 Sign-Off Gates (post-execution)

| # | Gate | Requirement | Result |
|---|------|-------------|--------|
| 1 | `meter_c7000_bulk.py` exists; `meter_c7000_hid.py` removed | MTR-02 | ✅ |
| 2 | `pytest tests/test_bridge_routes.py tests/test_bridge_auth.py` all pass | MTR-08, TST-02 | ✅ 6 passed |
| 3 | `lua5.4 tests/run.lua` — 139+ PASS, 0 FAIL | regression | ✅ 139 PASS |
| 4 | No calibration logic in `sekonic-bridge/` | MTR-01 | ✅ |
| 5 | Mock `/measure` + setup routes | MTR-07 | ✅ 3 setup smoke tests |
| 6 | Plugin wizard manual checklist | D-75 | ⏳ pending verify-work |

---

## Validation Sign-Off

- [x] All tasks have automated verify or manual gate
- [x] MTR-01, MTR-02, MTR-07, MTR-08 referenced
- [x] In-plugin setup preserved (D-75) — HTTP routes unchanged

**Approval:** automated gates passed 2026-07-02; human D-75 via `/gsd-verify-work 4`
