# Phase 4: Thin Bridge (Pi/Arduino) - Context

**Gathered:** 2026-07-02
**Updated:** 2026-07-02 (user revision: keep in-plugin setup for base version)
**Status:** Ready for planning
**Source:** `/gsd-discuss-phase 4` — all six gray areas; revised per user feedback

<domain>
## Phase Boundary

Refactor `sekonic-bridge/` into a **transport-only** HTTP server on the show LAN: USB bulk read → raw MeasurementRecord JSON. **No calibration, color math, goals, or SetColor logic on the Pi.**

**Thin means internal cleanup, not removing operator setup.** The **in-plugin Bridge Setup wizard** (main menu → discover → capture → optional learn_trigger) and **Bridge Status** screen **must keep working** in the base v0.4/v0.5 release — this is not deferred to Phase 5.

**In scope:** MTR-01, MTR-02, MTR-07, MTR-08; preserve plugin-facing setup HTTP contract  
**Out of scope:** Moving setup UX off-console entirely (Phase 5 may *enhance* flows but must not *replace* base wizard), auto-loop (MTR-05), bridge_client extract (ARCH-04 / Phase 5), Arduino firmware, TLS, Pi runbook polish (Phase 6)

</domain>

<decisions>
## Implementation Decisions

### Setup endpoint fate — REVISED (D-55–D-57)
- **D-55:** **Retain** `POST /capture`, `POST /learn_trigger`, and the full **`run_bridge_setup`** plugin flow (`GET /discover` → `POST /capture` → optional trigger discovery). Base version operators configure the Pi **from the MA3 plugin**, not from Pi-side docs or SSH.
- **D-56:** **Internal thinning only:** refactor setup implementation behind those routes (prefer C-7000 bulk fast-path via skreader; gate or skip HID probe loops when VID `0x0A41` and bulk protocol already active). **Do not delete** route handlers or break JSON shapes the plugin regex-parses.
- **D-57:** Keep `/capture` and `/learn_trigger` documented in `sekonic-bridge/README.md` as part of the supported operator setup path via the plugin wizard.

### `/status` JSON shape — REVISED (D-58–D-60)
- **D-58:** **Retain** existing setup flags on `/status`: `device_configured`, `protocol_captured`, `trigger_discovered` — `bridge_check_status()` and Bridge Status UI depend on them.
- **D-59:** **Add** `auth_required` (boolean) alongside existing fields when MTR-08 is implemented — do not remove fields to “slim” the contract.
- **D-60:** Mock mode (`--mock`) continues to report setup flags as today (auto-`true` for wizard progression in dev/CI smoke).

### API key auth — MTR-08 (D-61–D-65)
- **D-61:** Header name: **`X-Bridge-Key`** (matches ROADMAP and PROJECT.md).
- **D-62:** Bridge reads key from **`BRIDGE_API_KEY` environment variable** first; fallback to **`bridge_api_key`** in `sekonic-bridge/bridge_config.json` (example file committed).
- **D-63:** When key is **unset/empty**: no auth — current open-LAN behavior preserved.
- **D-64:** When key is **set**: reject missing or wrong key with **401** on **all operator-facing routes** — including **`/capture` and `/learn_trigger`** so setup wizard still works when the plugin sends the key from `config.json`.
- **D-65:** Extend `config.json` parse for optional `bridge_api_key`; `_http_request()` sends `X-Bridge-Key` on **every** bridge call (setup + measure + status).

### USB driver refactor — MTR-02 (D-66–D-69)
- **D-66:** Rename **`meter_c7000_hid.py` → `meter_c7000_bulk.py`**; class **`C7000HID` → `C7000Bulk`**. Update imports in server, packaging scripts, docs.
- **D-67:** Introduce thin **`MeterBackend` protocol**: `connect()`, `is_connected()`, `disconnect()`, `measure() -> dict`. `MockMeter` and `C7000Bulk` both satisfy it.
- **D-68:** **`GET /discover` unchanged for plugin wizard** — USB scan + persist VID/PID; **retain** `protocol_captured`, `trigger_discovered`, `trigger_cmd_hex` in `device_config.json` where setup routes write them today.
- **D-69:** Keep **`discover_device.py`** as optional Pi CLI helper; update paths after rename.

### Pi packaging scope (D-70–D-72)
- **D-70:** Phase 4 includes code + tests + import-path updates in `setup-pi.sh`, `start.sh`, `build-image.sh`, `sekonic-bridge.service`.
- **D-71:** Defer full network runbook to Phase 6 (UX-05).
- **D-72:** Extend Phase 3 pytest: auth tests (401 when key set); **optional** smoke tests for `/capture`/`/learn_trigger` in mock mode — **not** CI gates (Phase 3 D-47 unchanged). Update golden fixtures to add `auth_required` without removing setup flags.

### Arduino scope (D-73)
- **D-73:** Phase 4 is **Raspberry Pi only**; Arduino deferred to v2.

### Base-version plugin setup — NEW (D-75–D-76)
- **D-75:** **Non-negotiable:** Phase 4 execution must leave **Bridge Status** and **Bridge Setup wizard** callable from the plugin main menu with the same operator steps as today.
- **D-76:** Phase 5 (MTR-06) may improve retry/UX and remote-measure flows — it **must not** remove or require re-platforming of the base setup wizard as a prerequisite for using the bridge.

### Execution target (D-74)
- **D-74:** Product changes land on **`claude/lighttune-main`**; GSD artifacts on **`cursor/install-gsd-core-342d`**.

### Claude's Discretion
- How aggressively to skip HID probe loops internally when C-7000 bulk path is known — **without** changing outward HTTP behavior.
- FastAPI middleware vs dependency for API key check.
- Optional dev-only pytest for setup routes vs manual wizard verification only.

</decisions>

<canonical_refs>
## Canonical References

### Requirements & roadmap
- `.planning/ROADMAP.md` — Phase 4 goal (transport-only Pi); reconcile with D-75 base setup requirement
- `.planning/REQUIREMENTS.md` — MTR-01, MTR-02, MTR-07, MTR-08; MTR-06 plugin menu access
- `.planning/PROJECT.md` — thin bridge topology, X-Bridge-Key auth

### Prior phase context
- `.planning/phases/03-shared-test-strategy-ci/03-CONTEXT.md` — CI gates: /status, /measure, /discover only (setup routes optional smoke)
- `.planning/phases/01-canonical-merge-baseline/01-CONTEXT.md` — wizard docs remain until explicitly collapsed

### Codebase (must read before planning)
- `lua/SekonicCalibrator.lua` — `run_bridge_setup`, `bridge_check_status`, `_run_trigger_discovery`, `_http_request`
- `sekonic-bridge/server.py` — /capture, /learn_trigger, /discover, /status, /measure
- `sekonic-bridge/meter_c7000_hid.py` — bulk protocol (rename target)
- `sekonic-bridge/meter_mock.py`, `sekonic-bridge/device_config.json`
- `tests/test_bridge_routes.py`, `tests/fixtures/bridge_status_ok.json`
- `.planning/codebase/INTEGRATIONS.md`, `.planning/codebase/CONCERNS.md`

### External protocol
- https://github.com/kinglevel/skreader — C-7000 USB bulk command sequence

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`run_bridge_setup` in plugin:** Three-step wizard already wired to `/discover`, `/capture`, `/learn_trigger` — preserve end-to-end.
- **`bridge_check_status`:** Regex-parses setup flags from `/status` — flags must remain.
- **`MockMeter` + `--mock`:** Setup routes return success without USB for dev/demo.

### Established Patterns
- C-7000 fast path in `/discover` auto-sets protocol/trigger flags for VID `0x0A41`.
- Phase 3 CI tests core trio only; setup routes verified manually or optional pytest.

### Integration Points
- Rename meter module without changing HTTP paths or JSON keys the plugin parses.
- Auth header on all `_http_request` calls including wizard steps.

</code_context>

<specifics>
## Specific Ideas

- **User revision (2026-07-02):** “We need to keep the in plugin setup and functionality even for base version” — overrides prior D-55/D-58 decisions that removed setup endpoints and status flags.
- Original discuss used CONCERNS.md “collapse wizard” as default; user clarifies **collapse = internal dead-code cleanup**, not removing plugin-accessible setup.

</specifics>

<deferred>
## Deferred Ideas

- **Enhanced setup UX** (clearer errors, retry) — Phase 5 may add; base wizard must remain
- **Console-only setup alternative** — not for base version; optional future if ever needed
- **Arduino transport** — v2
- **TLS on bridge** — out of scope v0.4
- **Pi network runbook** — Phase 6

</deferred>

---

*Phase: 4-Thin Bridge (Pi/Arduino)*
*Context gathered: 2026-07-02*
*Revised: 2026-07-02 — in-plugin setup retained for base version*
