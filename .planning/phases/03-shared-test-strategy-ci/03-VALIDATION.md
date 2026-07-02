---
phase: 3
slug: shared-test-strategy-ci
status: approved
nyquist_compliant: true
wave_0_complete: true
created: 2026-07-02
updated: 2026-07-02
---

# Phase 3 — Validation Strategy

> Per-phase validation contract — signed off after execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Host framework** | Lua 5.4 — `tests/run.lua` |
| **Bridge framework** | pytest + Starlette TestClient (mock meter) |
| **Config files** | `sekonic-bridge/requirements-dev.txt` |
| **Quick host command** | `lua5.4 tests/run.lua` |
| **Full host command** | same (alias: `lua5.4 test_color_math.lua`) |
| **Bridge command** | `pytest tests/test_bridge_routes.py -v` |
| **CI workflow** | `.github/workflows/ci.yml` |
| **Estimated runtime** | ~15 seconds total |

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Automated Command | Status |
|---------|------|------|-------------|-------------------|--------|
| 03-01-01 | 01 | 1 | TST-01 | `test -f tests/lib_assert.lua` | ✅ green |
| 03-01-02 | 01 | 1 | TST-01 | `lua5.4 tests/run.lua` → 139 PASS | ✅ green |
| 03-01-03 | 01 | 1 | TST-01 | `lua5.4 test_color_math.lua` alias | ✅ green |
| 03-02-01 | 02 | 2 | TST-03 | four files under `tests/fixtures/` | ✅ green |
| 03-02-02 | 02 | 2 | TST-03 | golden fixture_db in host suite | ✅ green |
| 03-02-03 | 02 | 2 | TST-02 | `pytest tests/test_bridge_routes.py` | ✅ green |
| 03-03-01 | 03 | 3 | TST-04 | `.github/workflows/ci.yml` exists | ✅ green |
| 03-03-02 | 03 | 3 | TST-04 | README CI section | ✅ green |
| 03-03-03 | 03 | 3 | TST-01–04 | validation sign-off gates | ✅ green |

---

## Phase 3 Sign-Off Gates

| # | Gate | Result |
|---|------|--------|
| 1 | `lua5.4 tests/run.lua` — 133+ PASS, 0 FAIL (TST-01) | ✅ 139 PASS |
| 2 | `pytest tests/test_bridge_routes.py` — all pass (TST-02) | ✅ 3 passed |
| 3 | `tests/fixtures/` — four golden files (TST-03) | ✅ present |
| 4 | `.github/workflows/ci.yml` — host-lua + bridge-pytest (TST-04) | ✅ present |
| 5 | `lua5.4 test_color_math.lua` backward compat | ✅ exits 0 |
| 6 | `requirements-dev.txt` separate from runtime | ✅ yes |

**Remote CI:** First GitHub Actions run pending on push to `claude/lighttune-main` @ fb0df1f — workflow validated locally.

---

## ROADMAP Success Criteria

1. Host tests via `lua5.4 tests/run.lua` with 126+ assertions — **TRUE** (139)
2. Bridge route tests via pytest against mock — **TRUE**
3. Golden JSON fixtures for bridge + fixture DB — **TRUE**
4. GitHub Actions CI on push — **TRUE** (workflow committed; remote run pending)

---

## Validation Sign-Off

- [x] All tasks have automated verify
- [x] Host suite ≥133 PASS, 0 FAIL
- [x] Bridge pytest green with mock meter
- [x] Wave chain 03-01 → 03-02 → 03-03 complete
- [x] TST-01, TST-02, TST-03, TST-04 satisfied

**Approval:** approved 2026-07-02
