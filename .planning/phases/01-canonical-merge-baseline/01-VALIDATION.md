---
phase: 1
slug: canonical-merge-baseline
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-01
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Standalone Lua 5.4 harness (`test_color_math.lua`) |
| **Config file** | none |
| **Quick run command** | `lua5.4 test_color_math.lua` |
| **Full suite command** | same (single file) |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `lua5.4 test_color_math.lua` (when Lua changes) or `git diff --stat HEAD~1` (cherry-pick tasks)
- **After every plan wave:** Tree parity check vs `5cc8bf8`; doc grep gates
- **Before `/gsd-verify-work`:** Full suite must be green + manifest present
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-01 | 01 | 1 | BASE-01 | — | N/A | git | cherry-pick applies cleanly | ✅ | ⬜ pending |
| 01-02 | 02 | 2 | BASE-02 | T-1-01 | No secrets in git | grep | `! grep -q community_upload README.md` | ✅ | ⬜ pending |
| 01-03 | 02 | 2 | BASE-03 | — | config.json gitignored at root | grep | `grep config.json .gitignore` | ✅ | ⬜ pending |
| 01-04 | 03 | 3 | BASE-01 | — | Color math preserved | unit | `lua5.4 test_color_math.lua` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `lua5.4` on dev/CI host — install if missing before color-math gate
- [ ] Root `config.json` in `.gitignore` — add in alignment commit

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Tree parity vs research tip | BASE-01 | Git diff review | `git diff 5cc8bf8 --stat` after cherry-picks (README expected diff) |
| Cherry-pick manifest audit | BASE-01 | Human reads manifest | Verify 6 commits documented with rationale |
