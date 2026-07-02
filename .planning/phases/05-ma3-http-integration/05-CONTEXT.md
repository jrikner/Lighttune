# Phase 5: MA3 ↔ HTTP Integration - Context

**Gathered:** 2026-07-02
**Status:** Ready for planning
**Source:** `/gsd-discuss-phase 5` — all six gray areas

<domain>
## Phase Boundary

Harden and modularize the **GrandMA3 plugin ↔ Pi bridge HTTP client** so FOH operators can trigger remote C-7000 measurements with explicit failure UX, optional auto-loop convergence, and main-menu access to Bridge Status and Setup.

**In scope:** ARCH-04, MTR-03, MTR-04, MTR-05, MTR-06 — extract `bridge_client.lua`, structured errors/timeouts, enrich failure UX, verify auto-loop contract, Lua host tests for client layer.

**Out of scope:** Removing or re-platforming the in-plugin setup wizard (Phase 4 D-75/D-76); Pi bridge transport changes beyond consuming existing routes; full calibration UX modularization (Phase 6); HTTPS/TLS; auto-accept auto-loop without confirmation; new capabilities (WebRemote-specific UI, multi-bridge, concurrent groups).

</domain>

<decisions>
## Implementation Decisions

### `bridge_client.lua` extraction scope — ARCH-04 (D-77–D-81)
- **D-77:** Create **`lua/bridge_client.lua`** as a domain module loaded via the existing Phase 2 pattern (`require` + `loadfile` fallback in `load_domain_modules()`).
- **D-78:** **Move into the module:** raw HTTP transport (`_http_request` logic), auth header injection (`X-Bridge-Key` from config), route helpers for **`GET /status`**, **`POST /measure`**, **`GET /discover`**, **`POST /capture`**, **`POST /learn_trigger`**, JSON field extraction (regex parse today — no new JSON library).
- **D-79:** **Keep in monolith:** all `MessageBox` dialogs, `run_bridge_setup`, `show_bridge_status`, `_run_trigger_discovery`, calibration session orchestration, auto-loop UI. Monolith calls `bridge_client.*` and maps results to operator-facing text.
- **D-80:** **Structured client results:** every call returns either `{ ok=true, data=... }` or `{ ok=false, kind, message, hint?, http_status? }` where `kind` is one of: `connection`, `timeout`, `unauthorized`, `http`, `parse`, `validation` (e.g. cct out of range). Preserves MTR-03 parse contract and enables MTR-04 rich errors without UI in the module.
- **D-81:** **Timeouts (locked):** `/status` 5s, `/discover` 12s, `/capture` 35s, `/measure` 38s, `/learn_trigger` 120s — match current `SekonicCalibrator.lua` values unless research finds MA3 regression (document any change in plan).

### Remote measure failure UX — MTR-04 (D-82–D-85)
- **D-82:** **Preserve** the three-button pattern on bridge failure: **Retry Remote**, **Enter Manually**, **Cancel** — on first measure (`get_measurement_params`) and during auto-loop errors.
- **D-83:** **Enrich error text** using `bridge_client` structured errors: map HTTP **401** → auth/key mismatch hint; **503** → meter not connected; **409** → measurement in progress; **504** → timeout; **connection** → network/IP hint. Prefer bridge JSON `"error"` + `"hint"` fields when present.
- **D-84:** **Cancel never ends the outer calibration session** — only exits the current group’s inner loop (existing behavior). Retry does not increment attempt counter on auto-loop (preserve `attempt - 1` retry semantics).
- **D-85:** **Manual fallback always reachable** from any bridge error path — non-negotiable per PROJECT.md core value.

### Auto-loop operator control — MTR-05 (D-86–D-90)
- **D-86:** **Keep `MAX_AUTO_ATTEMPTS = 3`** per fixture group when bridge is active and operator has not switched to manual.
- **D-87:** **First remote measure:** keep Remote / Enter Manually / Cancel choice dialog, then Accept / Re-measure / Enter Manually confirmation on success (existing flow).
- **D-88:** **Auto-loop attempts 2+:** keep per-measurement **Accept / Enter Manually / Cancel** confirmation — do **not** auto-accept silently in Phase 5 (operator exit at any point outweighs speed).
- **D-89:** **Stuck-after-3 dialog unchanged:** Accept & Move On / Try Again / Skip Group. Try Again resets `loop_count` only, not session goals.
- **D-90:** **`user_manual` flag** remains sticky for the remainder of the group once operator chooses manual entry (existing behavior).

### When to offer “Remote Measurement” — MTR-03 (D-91–D-93)
- **D-91:** Offer remote path only when **`bridge_ip` is configured AND session meter is C-7000** (`goals.meter == METER_C7000`). Bridge hardware is C-7000-only; C-700/C-800 sessions use manual entry only.
- **D-92:** If `bridge_ip` is set but operator chose C-700/C-800 in session goals, **skip** the Remote/Manual choice dialog; proceed directly to manual prompts. Optional one-line note in first manual prompt: “Bridge remote measure requires C-7000 meter selection.”
- **D-93:** Do **not** add a mandatory pre-flight `/status` gate before every remote measure in Phase 5 — unreachable bridge is handled by existing retry/error UX. Bridge Status screen remains the place to diagnose connectivity.

### Bridge Status / Setup menu scope — MTR-06 (D-94–D-98)
- **D-94:** **Main menu entry remains:** “Bridge Status” (or “Bridge Status (not configured)”) as today — Phase 5 verifies and tests, does not relocate.
- **D-95:** **Setup wizard preserved end-to-end:** `run_bridge_setup` (discover → capture → optional learn_trigger) callable from Bridge Status — Phase 4 D-75/D-76 non-negotiable.
- **D-96:** **Enhance Bridge Status display** to include **`auth_required`** and **`last_error`** from `/status` when reachable (extend status parse beyond setup flags). Show auth hint when `auth_required` true and plugin lacks `bridge_api_key`.
- **D-97:** **No new “Configure Bridge” interrupt** mid-calibration when `bridge_ip` missing — operator configures via main menu + README. Defer shortcut to Phase 6 UX polish.
- **D-98:** Trigger-discovery button on Bridge Status (when protocol ready but trigger not discovered) stays — wired through `bridge_client.learn_trigger`.

### Host testing for bridge layer — TST-01 extension (D-99–D-101)
- **D-99:** Add **`tests/test_bridge_client.lua`** with table-driven cases: mock HTTP response bodies → parsed measurement/status tables; error mapping for 401/503/504/connection failures; auth header presence when `bridge_api_key` set.
- **D-100:** Register in **`tests/run.lua`** alongside color_math/fixture_db/goals tests. Target **15+ assertions** for client layer (parse + error kinds + edge cases).
- **D-101:** **Keep Phase 3/4 pytest** as Pi-side contract tests — no duplication of full HTTP stack in Lua. MA3 console behavior remains Phase 7 UAT.

### Claude's Discretion
- Exact function names on `bridge_client` module table (`fetch_measurement` vs `measure`).
- Whether to inject a test seam for HTTP transport (stub `send_request`) vs pure string-fixture tests on parse helpers.
- Minor Bridge Status copy/layout for new auth/error lines.

</decisions>

<canonical_refs>
## Canonical References

### Requirements & roadmap
- `.planning/ROADMAP.md` — Phase 5 goal, success criteria, research flag (LuaSocket, timeouts, blocking UI)
- `.planning/REQUIREMENTS.md` — ARCH-04, MTR-03, MTR-04, MTR-05, MTR-06
- `.planning/PROJECT.md` — core value (speed + accuracy), manual fallback, thin bridge topology

### Prior phase context (locked)
- `.planning/phases/04-thin-bridge-pi-arduino/04-CONTEXT.md` — D-75/D-76 setup wizard preserved; D-65 auth header on every call; setup routes unchanged
- `.planning/phases/03-shared-test-strategy-ci/03-CONTEXT.md` — CI gates, pytest mock meter pattern
- `.planning/phases/02-plugin-hardening-test-seams/02-CONTEXT.md` — module loader pattern (D-23)

### Codebase (must read before planning)
- `lua/SekonicCalibrator.lua` — Section 2c (`_http_request`, `bridge_fetch_measurement`, `bridge_check_status`, `run_bridge_setup`, `show_bridge_status`, auto-loop ~1544–1700)
- `lua/goals.lua` — `goals_met()` used by auto-loop
- `sekonic-bridge/server.py` — route contracts, error JSON shapes, auth
- `tests/run.lua`, `tests/test_bridge_routes.py`, `tests/test_bridge_auth.py`
- `.planning/codebase/INTEGRATIONS.md` — HTTP client constraints, error codes
- `.planning/codebase/CONCERNS.md` — auto-loop blocking, regex JSON fragility, TLCI optional field

### External
- No external specs beyond skreader (Pi-side, Phase 4) — plugin uses bridge JSON contract only

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **Section 2c inline client:** Full remote measure, setup wizard, and status checks already implemented — Phase 5 extracts, does not redesign.
- **Phase 2 module loader:** `load_domain_modules()` + `try_require` pattern for `bridge_client.lua`.
- **Phase 4 auth:** `_http_request` already sends `X-Bridge-Key`; move unchanged semantics into module.
- **Auto-loop:** `MAX_AUTO_ATTEMPTS`, `goals_met`, `user_manual`, stuck dialog — behavior locked, add tests where feasible.

### Established Patterns
- HTTP/1.0 over raw TCP via `require("socket")` — no HTTPS, no `socket.http`.
- Regex JSON parsing — maintain until MA3 JSON library verified (out of Phase 5 scope).
- Bridge errors use `goto bridge_retry` — refactor to structured errors without changing operator button labels.

### Integration Points
- `get_measurement_params()` → `bridge_client.fetch_measurement()`
- `bridge_check_status()` → `bridge_client.check_status()` + extended fields
- `run_bridge_setup` / `_run_trigger_discovery` → `bridge_client` setup helpers
- `tests/run.lua` → new `test_bridge_client.lua`

</code_context>

<specifics>
## Specific Ideas

- User selected **All** six gray areas — decisions favor **preserve proven v0.5 UX**, extract/test the client layer, and align remote offer with C-7000-only bridge hardware.
- Phase 4 user override precedent: **do not remove** in-plugin setup; Phase 5 **enhances** status/errors only.

</specifics>

<deferred>
## Deferred Ideas

- **Auto-accept on clean auto-loop reads** (skip confirmation when parse succeeds) — Phase 6 speed polish; CONCERNS.md notes blocking UI tradeoff
- **“Configure Bridge” shortcut** when `bridge_ip` missing mid-calibration — Phase 6 UX
- **Retry backoff / connection pooling** on HTTP client — not needed for single-meter show LAN
- **Real MA3 LuaSocket verification** — Phase 7 UAT (ROADMAP research flag)
- **TLCI optional-field alignment** mock vs hardware — track in Phase 7; note in client validation only if trivial

</deferred>

---

*Phase: 5-MA3 ↔ HTTP Integration*
*Context gathered: 2026-07-02*
