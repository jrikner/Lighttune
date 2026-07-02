# Phase 4: Thin Bridge (Pi/Arduino) - Context

**Gathered:** 2026-07-02
**Status:** Ready for planning
**Source:** `/gsd-discuss-phase 4` — all six gray areas (user: "All")

<domain>
## Phase Boundary

Refactor `sekonic-bridge/` into a **transport-only** HTTP server on the show LAN: USB bulk read → raw MeasurementRecord JSON. No calibration, color math, goals, or operator setup wizard on the Pi.

**In scope:** MTR-01, MTR-02, MTR-07, MTR-08 (bridge-side + minimal plugin header support per ROADMAP success criteria #3)  
**Out of scope:** Plugin setup wizard relocation (Phase 5 / MTR-06), auto-loop (MTR-05), bridge_client extract (ARCH-04 / Phase 5), Arduino firmware, TLS, community upload, Pi image/runbook polish (Phase 6)

**Inter-phase note:** Removing `/capture`, `/learn_trigger`, and setup flags from `/status` **breaks the current in-plugin setup wizard** until Phase 5 replaces those flows on-console. Acceptable — Phase 4 deploys thinned bridge; Phase 5 ships plugin fixes immediately after.

</domain>

<decisions>
## Implementation Decisions

### Setup endpoint fate (D-55–D-57)
- **D-55:** **Remove** `POST /capture` and `POST /learn_trigger` route handlers from `server.py` entirely (return **404** if legacy clients hit old paths — no stub bodies).
- **D-56:** Delete associated server-side helpers that exist only for HID wizard probing: `_build_trigger_candidates()`, HID-oriented capture fallback paths, and `learn_trigger` probe loop. Keep skreader bulk sequence in the meter driver only.
- **D-57:** Remove `/capture` and `/learn_trigger` from bridge README operator docs; point setup to Phase 5 console wizard (placeholder note until Phase 6 runbook).

### `/status` JSON shape after thinning (D-58–D-60)
- **D-58:** **Remove** setup flags from `/status`: `device_configured`, `protocol_captured`, `trigger_discovered`. Slim contract:
  ```json
  { "status", "meter", "connected", "uptime_s", "last_error", "version", "auth_required" }
  ```
- **D-59:** Add **`auth_required`** (boolean): `true` when bridge has `bridge_api_key` configured, `false` when open LAN. Helps Phase 5 Bridge Status UI without reintroducing wizard flags.
- **D-60:** Mock mode (`--mock`) uses the same slim `/status` shape — no special-casing setup flags to `true`.

### API key auth — MTR-08 (D-61–D-65)
- **D-61:** Header name: **`X-Bridge-Key`** (matches ROADMAP and PROJECT.md).
- **D-62:** Bridge reads key from **`BRIDGE_API_KEY` environment variable** first; fallback to **`bridge_api_key`** field in new `sekonic-bridge/bridge_config.json` (optional file, gitignored example committed as `bridge_config.json.example`).
- **D-63:** When key is **unset/empty**: no auth — current open-LAN behavior preserved (show VLAN trust model).
- **D-64:** When key is **set**: reject missing or wrong key with **401** on **all three routes** (`GET /status`, `POST /measure`, `GET /discover`). No anonymous fallback.
- **D-65:** **Minimal plugin change in Phase 4** (ROADMAP success criteria #3): extend `config.json` parse for optional `bridge_api_key`; `_http_request()` sends `X-Bridge-Key` header when field is non-empty. Full wizard/status UX updates remain Phase 5.

### USB driver refactor — MTR-02 (D-66–D-69)
- **D-66:** Rename **`meter_c7000_hid.py` → `meter_c7000_bulk.py`**; class **`C7000HID` → `C7000Bulk`**. Update all imports (`server.py`, `setup-pi.sh`, `build-image.sh`, docs).
- **D-67:** Introduce thin **`MeterBackend` protocol** (typing.Protocol or documented duck-type): `connect()`, `is_connected()`, `disconnect()`, `measure() -> dict`. `MockMeter` and `C7000Bulk` both satisfy it — no behavior change, clearer seam for tests.
- **D-68:** **`GET /discover` stays minimal**: USB scan → `{ configured, manufacturer, product, vendor_id, product_id, devices[] }`. May persist **VID/PID only** to `device_config.json` for driver override — drop `protocol_captured`, `trigger_discovered`, `trigger_cmd_hex` from persisted schema.
- **D-69:** Keep **`discover_device.py`** as optional Pi CLI helper (not part of HTTP surface); update imports/paths after rename.

### Pi packaging scope (D-70–D-72)
- **D-70:** Phase 4 includes **code + tests + import-path updates** in `setup-pi.sh`, `start.sh`, `build-image.sh`, `sekonic-bridge.service` (rename references only — no image rebuild campaign).
- **D-71:** **Defer** full network runbook, firewall guidance, and operator-facing Pi docs overhaul to **Phase 6** (UX-05).
- **D-72:** Extend Phase 3 pytest suite: auth tests (401 when key set), confirm removed routes 404, update golden `bridge_status_ok.json` to slim shape + optional `auth_required`.

### Arduino scope (D-73)
- **D-73:** Phase 4 is **Raspberry Pi only**. ROADMAP "Arduino" title is aspirational — **no Arduino implementation** in v0.4; document as v2 deferred transport. Do not add Arduino-specific files or CI jobs.

### Execution target (D-74)
- **D-74:** Product changes land on **`claude/lighttune-main`**; GSD artifacts on **`cursor/install-gsd-core-342d`** per D-15 convention.

### Claude's Discretion
- Exact FastAPI dependency/middleware pattern for API key check (middleware vs per-route decorator).
- Whether to delete `device_config.json` fields on read migration or ignore stale keys.
- `bridge_config.json` vs env-only if implementation is simpler with env-only for systemd unit.

</decisions>

<canonical_refs>
## Canonical References

### Requirements & roadmap
- `.planning/ROADMAP.md` — Phase 4 goal, success criteria (MTR-01/02/07 + API key criterion #3)
- `.planning/REQUIREMENTS.md` — MTR-01, MTR-02, MTR-07, MTR-08
- `.planning/PROJECT.md` — thin bridge topology, `X-Bridge-Key` auth decision

### Prior phase context
- `.planning/phases/03-shared-test-strategy-ci/03-CONTEXT.md` — CI tests three routes only; auth tests deferred to Phase 4
- `.planning/phases/01-canonical-merge-baseline/01-CONTEXT.md` — wizard collapse deferred Phase 4–6; MTR-08 Phase 4

### Codebase (must read before planning)
- `sekonic-bridge/server.py` — routes to remove/thin; lifespan; mock global
- `sekonic-bridge/meter_c7000_hid.py` — bulk protocol (rename target)
- `sekonic-bridge/meter_mock.py` — MockMeter progression (MTR-07)
- `sekonic-bridge/device_config.json` — persisted fields to slim
- `lua/SekonicCalibrator.lua` — `_http_request`, `bridge_check_status`, setup wizard calls (minimal header change only in Phase 4)
- `tests/test_bridge_routes.py`, `tests/fixtures/bridge_status_ok.json` — update for slim status + auth
- `.planning/codebase/INTEGRATIONS.md` — HTTP contract, error codes
- `.planning/codebase/CONCERNS.md` — HID vs bulk naming debt, wizard dead paths

### External protocol
- https://github.com/kinglevel/skreader — C-7000 USB bulk command sequence (RT1/RM0/ST/NR)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`meter_mock.py` / `MockMeter`:** Already implements MTR-07 progression; keep as dev/CI backend unchanged except MeterBackend typing.
- **`tests/conftest.py` + TestClient:** Extend for auth header and 401 cases without subprocess uvicorn.
- **Phase 3 golden fixtures:** Update `bridge_status_ok.json`; add `bridge_status_auth_required.json` if needed.

### Established Patterns
- **`asyncio.Lock` on `/measure`:** Keep — prevents concurrent measurements (409).
- **`_use_mock_global` + lifespan:** Keep mock wiring; slim status response in both modes.
- **Regex JSON parse in plugin:** Phase 4 only adds header to `_http_request`; do not refactor parse logic here.

### Integration Points
- **`server.py` `_load_meter()`:** Switch import to `meter_c7000_bulk.C7000Bulk`.
- **`config.json` / plugin:** Add optional `bridge_api_key` field alongside `bridge_ip` / `bridge_port`.
- **systemd / setup scripts:** Update filenames in copy lists and WorkingDirectory invocations.

</code_context>

<specifics>
## Specific Ideas

- User selected **all six gray areas** for discussion — decisions above apply project-aligned defaults from ROADMAP, CONCERNS.md, and Phase 1/3 carry-forward without per-question back-and-forth.
- CONCERNS.md explicitly recommends: rename to bulk module, collapse wizard, remove HID probe loop when skreader protocol active — adopted in D-55–D-57 and D-66.

</specifics>

<deferred>
## Deferred Ideas

- **Console-side setup wizard** (discover + test measure UX on MA3) — Phase 5 / MTR-06
- **Plugin Bridge Status UI** updates for slim `/status` and `auth_required` — Phase 5 (beyond minimal header in D-65)
- **Arduino HTTP transport** — v2 / future milestone
- **TLS / HTTPS on bridge** — out of scope v0.4 (show LAN VLAN trust)
- **Pi image rebuild + network runbook** — Phase 6 / UX-05
- **Wireshark / passive capture for unknown meters** — v2 or optional dev tool, not thin-bridge HTTP surface

</deferred>

---

*Phase: 4-Thin Bridge (Pi/Arduino)*
*Context gathered: 2026-07-02*
