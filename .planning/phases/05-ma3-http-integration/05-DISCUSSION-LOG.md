# Phase 5: MA3 ↔ HTTP Integration - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-02
**Phase:** 5-MA3 ↔ HTTP Integration
**Areas discussed:** bridge_client extraction, remote failure UX, auto-loop control, remote offer gating, Bridge Status/Setup, host testing

---

## 1. bridge_client.lua extraction scope

| Option | Description | Selected |
|--------|-------------|----------|
| HTTP transport only | Move `_http_request` + auth header | |
| Full client API + structured errors | Transport + all route helpers + `{ok, kind, message}` results; UI stays in monolith | ✓ |
| Minimal rename only | Keep everything inline, rename functions | |

**User's choice:** All areas — full client API extraction with structured errors (recommended).
**Notes:** Matches ARCH-04; follows Phase 2 module loader pattern.

---

## 2. Remote measure failure UX (MTR-04)

| Option | Description | Selected |
|--------|-------------|----------|
| Keep Retry / Manual / Cancel as-is | No copy changes | |
| Keep pattern + enrich errors | Same buttons; map HTTP codes and JSON hints to operator text | ✓ |
| Simplify dialogs | Fewer confirmation steps | |

**User's choice:** All areas — enrich errors, preserve three-button pattern.
**Notes:** Cancel exits group inner loop only; manual always available.

---

## 3. Auto-loop operator control (MTR-05)

| Option | Description | Selected |
|--------|-------------|----------|
| Per-cycle confirm (current) | Accept / Manual / Cancel on each auto-measurement | ✓ |
| Auto-accept on clean parse | Faster; less operator control | |
| Explicit Stop auto-loop button | New UI between cycles | |

**User's choice:** All areas — keep per-cycle confirmation and stuck-after-3 dialog; MAX_AUTO_ATTEMPTS = 3.

---

## 4. When to offer Remote Measurement

| Option | Description | Selected |
|--------|-------------|----------|
| bridge_ip set (any meter) | Current behavior | |
| bridge_ip + C-7000 session meter | Align with C-7000-only bridge hardware | ✓ |
| bridge_ip + connected status pre-check | Gate before every remote | |

**User's choice:** All areas — C-7000 session meter required for remote offer; no mandatory pre-flight per measure.

---

## 5. Bridge Status / Setup menu scope (MTR-06)

| Option | Description | Selected |
|--------|-------------|----------|
| Verify existing menu only | Tests/docs | |
| Enhance status + preserve wizard | Add auth_required/last_error; keep setup wizard (D-75) | ✓ |
| Add mid-calibration configure shortcut | New dialog when bridge_ip missing | |

**User's choice:** All areas — enhance Bridge Status; no mid-calibration configure shortcut in Phase 5.

---

## 6. Host testing for bridge layer

| Option | Description | Selected |
|--------|-------------|----------|
| Lua unit tests for bridge_client | Parse + error mapping fixtures in tests/run.lua | ✓ |
| Pytest only | Pi-side contract tests | |
| Both Lua + pytest | Lua client tests + existing pytest | ✓ |

**User's choice:** All areas — add test_bridge_client.lua to host runner; keep pytest unchanged.

---

## Claude's Discretion

- Module function naming and optional HTTP transport test seam.
- Bridge Status copy for new auth/error lines.

## Deferred Ideas

- Auto-accept auto-loop reads (Phase 6)
- Configure Bridge shortcut mid-calibration (Phase 6)
- MA3 LuaSocket hardware verification (Phase 7)
