---
phase: 6
slug: operator-ux-docs-show-readiness
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-02
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Lua 5.4 host tests + pytest (bridge) |
| **Config file** | `tests/run.lua` (host); `tests/test_bridge_routes.py` (bridge) |
| **Quick run command** | `lua5.4 tests/run.lua` |
| **Full suite command** | `lua5.4 tests/run.lua && pytest tests/test_bridge_routes.py -v` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `lua5.4 tests/run.lua`
- **After every plan wave:** Run full suite command above
- **Before `/gsd-verify-work`:** Full suite must be green + doc grep audit for TOP-01/UX-05
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 06-01-01 | 01 | 1 | TOP-01, UX-05 | — | macOS runbook documented | doc grep | `grep -n '127.0.0.1' README.md sekonic-bridge/README.md` | ❌ W0 | ⬜ pending |
| 06-01-02 | 01 | 1 | D-105, D-120 | — | config.lua loads paths | unit | `lua5.4 tests/run.lua` | ❌ W0 | ⬜ pending |
| 06-02-01 | 02 | 2 | UX-01, UX-02 | — | patch_api extracted | regression | `lua5.4 tests/run.lua` | ✅ | ⬜ pending |
| 06-02-02 | 02 | 2 | CAL-04 | — | fixture_apply SetColor | regression | `lua5.4 tests/run.lua` | ✅ | ⬜ pending |
| 06-03-01 | 03 | 3 | CAL-01–06, UX-03–04 | — | ui/* + calibration extracted | grep + regression | `grep -q 'calibration.lua' lua/ && lua5.4 tests/run.lua` | ❌ W0 | ⬜ pending |
| 06-03-02 | 03 | 3 | DB-02, DB-03 | — | history + prefill preserved | regression | `lua5.4 tests/run.lua` | ✅ | ⬜ pending |
| 06-03-03 | 03 | 3 | D-120, D-121 | — | full suite green | regression | full suite command | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Fix `goals` module vs `session_goals` variable shadowing in monolith
- [ ] Merge `bridge_client.lua` + `tests/test_bridge_client.lua` from product branch if absent
- [ ] Update `config.json.example` to `bridge_ip: "127.0.0.1"`
- [ ] Add macOS runbook sections before Pi sections (TOP-01, UX-05)
- [ ] Fix sekonic-bridge README (config path, remove stale fields, TCP not socket.http)
- [ ] Add `tests/test_config.lua` for config path/parse helpers

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Session goals + modes | CAL-01, CAL-02 | MA3 MessageBox | Phase 7 onPC UAT |
| Inner loop + auto-loop | CAL-03 | Console SetColor | Phase 7 UAT |
| Manual meter entry | CAL-06 | Console UI | Phase 7 UAT |
| Patch make/model | UX-01 | Patch API | Phase 7 with showfile |
| Assessment + gel hints | UX-03, UX-04 | Console UI | Phase 7 UAT |
| macOS bridge + USB | TOP-01 | Hardware | curl `/status` on Mac with C-7000 |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
