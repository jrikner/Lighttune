---
phase: 3
slug: shared-test-strategy-ci
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-02
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Host framework** | Lua 5.4 — `tests/run.lua` |
| **Bridge framework** | pytest + httpx (ASGITransport) |
| **Config files** | `sekonic-bridge/requirements-dev.txt` |
| **Quick host command** | `lua5.4 tests/run.lua` |
| **Full host command** | same (alias: `lua5.4 test_color_math.lua`) |
| **Bridge command** | `pytest tests/test_bridge_routes.py -v` |
| **Estimated runtime** | ~15 seconds total |

---

## Sampling Rate

- **After every task commit:** Run affected suite (host and/or pytest)
- **After every plan wave:** Full host + bridge pytest locally
- **Before `/gsd-verify-work`:** CI workflow green on push
- **Max feedback latency:** 60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Status |
|---------|------|------|-------------|-----------|-------------------|--------|
| 03-01-01 | 01 | 1 | TST-01 | unit | `test -f tests/lib_assert.lua` | ⬜ pending |
| 03-01-02 | 01 | 1 | TST-01 | unit | `lua5.4 tests/run.lua` → 133+ PASS | ⬜ pending |
| 03-01-03 | 01 | 1 | TST-01 | smoke | `lua5.4 test_color_math.lua` alias | ⬜ pending |
| 03-02-01 | 02 | 2 | TST-03 | static | four files under `tests/fixtures/` | ⬜ pending |
| 03-02-02 | 02 | 2 | TST-03 | unit | golden fixture_db in host suite | ⬜ pending |
| 03-02-03 | 02 | 2 | TST-02 | integration | `pytest tests/test_bridge_routes.py` | ⬜ pending |
| 03-03-01 | 03 | 3 | TST-04 | CI | `.github/workflows/ci.yml` exists | ⬜ pending |
| 03-03-02 | 03 | 3 | TST-04 | CI | both jobs green on push | ⬜ pending |

---

## Wave 0 Requirements

- [ ] `lua5.4` on executor host — apt install if missing
- [ ] Python 3.12 + venv for local pytest verification
- [ ] Split test files from monolithic `test_color_math.lua`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| CI first run on GitHub | TST-04 | Requires push to remote | Verify Actions tab shows green after merge |

---

## Validation Sign-Off

- [ ] All tasks have automated verify
- [ ] Host suite ≥133 PASS, 0 FAIL
- [ ] Bridge pytest green with mock meter
- [ ] `nyquist_compliant: true` in frontmatter

**Approval:** pending
