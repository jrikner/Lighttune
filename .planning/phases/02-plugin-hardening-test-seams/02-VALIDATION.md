---
phase: 2
slug: plugin-hardening-test-seams
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-01
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Standalone Lua 5.4 harness (`test_color_math.lua` at repo root) |
| **Module path** | `package.path = package.path .. ";./lua/?.lua"` (host); entry loader sets `plugin_dir/lua/?.lua` (console) |
| **Config file** | none |
| **Quick run command** | `lua5.4 test_color_math.lua` |
| **Full suite command** | same (Phase 2); Phase 3 adds unified runner |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `lua5.4 test_color_math.lua` when Lua modules or tests change
- **After every plan wave:** Grep entry file for removed Section 2/2b bodies; confirm `require`/`dofile` loader present
- **Before `/gsd-verify-work`:** 126+ color-math PASS + goals_met tests green + single ComponentLua in plugin.xml
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 1 | ARCH-01 | — | N/A | unit | `lua5.4 test_color_math.lua` | ✅ | ⬜ pending |
| 02-01-02 | 01 | 1 | ARCH-05 | — | Single plugin entry | grep | `grep -c ComponentLua plugin.xml` → 1 | ✅ | ⬜ pending |
| 02-02-01 | 02 | 2 | ARCH-02 | T-2-01 | Quote escape in fixture names | unit | JSON roundtrip tests with `"` in make | post-02 | ⬜ pending |
| 02-02-02 | 02 | 2 | DB-01 | — | best_* flags preserved | unit | existing fixture_db tests via require | ✅ | ⬜ pending |
| 02-03-01 | 03 | 3 | ARCH-03 | — | goals_met host-testable | unit | goals_met boundary tests | post-03 | ⬜ pending |
| 02-03-02 | 03 | 3 | ARCH-01 | — | No inline duplicate | grep | `! grep -q "Inline copies" test_color_math.lua` | post-03 | ⬜ pending |
| 02-03-03 | 03 | 3 | ARCH-05 | — | Dead base64 removed | grep | `! grep -q base64_encode lua/SekonicCalibrator.lua` | post-03 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `lua5.4` on executor host — required for all gates (same as Phase 1)
- [ ] Execution checkout `claude/lighttune-main` — planning branch Lua is v0.4 stale

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| MA3 console `require` path | ARCH-05 | No MA3 in CI | Deferred to Phase 7 UAT; dofile fallback must exist in loader |
| Entry file line reduction | D-21 | Approximate metric | `wc -l lua/SekonicCalibrator.lua` should drop ~400–500 from ~2046 baseline |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
