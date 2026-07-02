---
phase: 5
slug: ma3-http-integration
status: signed-off
nyquist_compliant: true
wave_0_complete: true
created: 2026-07-02
executed: 2026-07-02
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Host framework** | Lua 5.4 — `tests/run.lua` (regression + new bridge_client tests) |
| **Bridge framework** | pytest (unchanged — Phase 3/4 contract tests) |
| **New host tests** | `tests/test_bridge_client.lua` |
| **Quick host command** | `lua5.4 tests/run.lua` |
| **Quick bridge command** | `pytest tests/test_bridge_routes.py tests/test_bridge_auth.py tests/test_bridge_setup_routes.py -q` |
| **Estimated runtime** | ~25 seconds |

---

## Sampling Rate

- **After Wave 1:** `grep bridge_client lua/`; module loads without error in host test stub
- **After Wave 2:** Full host suite + pytest regression
- **Before `/gsd-verify-work`:** D-75 wizard manual checklist (inherited from Phase 4 UAT pattern)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Automated Command | Status |
|---------|------|------|-------------|-------------------|--------|
| 05-01-01 | 01 | 1 | ARCH-04 | `test -f lua/bridge_client.lua` | ✅ pass |
| 05-01-02 | 01 | 1 | ARCH-04, MTR-03 | grep `ok`/`kind`/`fetch_measurement` in bridge_client | ✅ pass |
| 05-01-03 | 01 | 1 | ARCH-04 | loader includes bridge_client in domain table | ✅ pass |
| 05-02-01 | 02 | 2 | MTR-03, MTR-04 | monolith uses bridge_client; error mapper exists | ✅ pass |
| 05-02-02 | 02 | 2 | MTR-06 | Bridge Status shows auth_required/last_error | ✅ pass |
| 05-02-03 | 02 | 2 | MTR-03 | C7000-only remote gate in get_measurement_params | ✅ pass |
| 05-03-01 | 03 | 3 | MTR-05 | auto-loop still uses bridge_client; MAX_AUTO_ATTEMPTS=3 | ✅ pass |
| 05-03-02 | 03 | 3 | D-99 | `tests/test_bridge_client.lua` 15+ assertions | ✅ pass (22 asserts, 161 total PASS) |
| 05-03-03 | 03 | 3 | ARCH-04–MTR-06 | full validation sign-off | ✅ pass |

---

## Wave 0 Requirements

- [x] Phase 4 bridge on `claude/lighttune-main` (auth + routes)
- [x] Phase 3 host runner (`tests/run.lua`)
- [x] `lua5.4` available in CI

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Remote measure on MA3 | MTR-03, ROADMAP research flag | No MA3 in CI | Phase 7 UAT |
| Auto-loop blocking UI | MTR-05 | Modal MessageBox | Operator confirms Accept/Cancel on console |
| Bridge Setup wizard | D-75 (Phase 4) | Plugin UI | discover → capture → status flags |

---

## Phase 5 Sign-Off Gates (post-execution)

| # | Gate | Requirement | Result |
|---|------|-------------|--------|
| 1 | `lua/bridge_client.lua` exists; monolith Section 2c delegates to module | ARCH-04 | ✅ 2026-07-02 |
| 2 | `lua5.4 tests/run.lua` — 154+ PASS (139 baseline + 15 bridge), 0 FAIL | TST-01 extension | ✅ 161 PASS |
| 3 | `pytest` bridge suite green (9 tests) | regression | ✅ 9 passed |
| 4 | Remote offer gated on C-7000 session meter | MTR-03, D-91 | ✅ |
| 5 | Retry/Manual/Cancel preserved; enriched errors | MTR-04 | ✅ |
| 6 | Auto-loop 3-attempt contract unchanged | MTR-05 | ✅ |
| 7 | Bridge Status + Setup from main menu | MTR-06, D-75 | ✅ (manual UAT Phase 7) |

---

## Validation Sign-Off

- [x] All tasks have automated verify or manual gate
- [x] ARCH-04, MTR-03, MTR-04, MTR-05, MTR-06 referenced
- [x] Phase 4 setup wizard preserved

**Approval:** automated gates passed 2026-07-02; MA3 manual UAT deferred to Phase 7 / verify-work
