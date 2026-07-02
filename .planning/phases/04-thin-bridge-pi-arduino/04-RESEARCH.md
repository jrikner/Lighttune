---
phase: 4
slug: thin-bridge-pi-arduino
status: complete
created: 2026-07-02
---

# Phase 4 — Research

> Thin bridge refactor: bulk driver rename, API key auth, in-plugin setup preserved.

## Summary

Phase 4 refactors `sekonic-bridge/` for **transport-only** operation (USB bulk → raw JSON) while **keeping the full in-plugin setup wizard** (`/discover`, `/capture`, `/learn_trigger`, setup flags on `/status`). Research confirms the prototype is complete — execution is rename, auth, internal cleanup, and test updates, not greenfield discovery.

## Current State (post Phase 3 @ fb0df1f)

| Component | State |
|-----------|--------|
| `server.py` | 636 lines; 5 HTTP routes; FastAPI + lifespan mock |
| `meter_c7000_hid.py` | 201 lines; skreader bulk protocol (misnamed HID) |
| `meter_mock.py` | MockMeter with improving progression (MTR-07) |
| Plugin | `run_bridge_setup`, `bridge_check_status`, `_http_request` (no auth header yet) |
| CI | pytest on `/status`, `/measure`, `/discover` only (Phase 3 D-47) |
| `load_config()` | Parses `bridge_ip`, `bridge_port` only — no `bridge_api_key` |

## Locked Decisions (from 04-CONTEXT.md)

- **D-55–D-57:** Retain setup routes; internal thinning only
- **D-58–D-60:** Keep setup flags on `/status`; add `auth_required`
- **D-61–D-65:** `X-Bridge-Key`; env + `bridge_config.json`; 401 on all routes when set; plugin sends header on every call
- **D-66–D-69:** Rename to `meter_c7000_bulk.py` / `C7000Bulk`; MeterBackend protocol
- **D-75–D-76:** Base-version in-plugin setup non-negotiable

## Technical Approach

### Wave 1 — Driver rename + MeterBackend (MTR-02)

1. Add `sekonic-bridge/meter_backend.py` with `typing.Protocol` (or ABC) defining `connect`, `is_connected`, `disconnect`, `measure`.
2. Rename `meter_c7000_hid.py` → `meter_c7000_bulk.py`; class `C7000Bulk`.
3. Update imports: `server.py`, `setup-pi.sh`, `build-image.sh`, `discover_device.py`, README references.
4. `_load_meter()` unchanged behavior; grep confirms no remaining `meter_c7000_hid` / `C7000HID`.

### Wave 2 — API key auth (MTR-08)

1. **Bridge:** Read `BRIDGE_API_KEY` env, then `bridge_config.json` → `bridge_api_key`. FastAPI dependency or middleware checks `X-Bridge-Key` on every route when key configured.
2. **`/status`:** Add `auth_required: bool`.
3. **Plugin:** Extend `load_config()` for `bridge_api_key`; extend `_http_request()` to append `X-Bridge-Key: …` header line when set (HTTP/1.0 raw request — insert before `\r\n\r\n`).
4. **Tests:** `tests/conftest.py` fixture with key set; tests for 401 without header, 200 with header; update `bridge_status_ok.json` golden.
5. **Example:** `sekonic-bridge/bridge_config.json.example`.

### Wave 3 — Internal setup thinning + validation (MTR-01, MTR-07, D-56)

1. **C-7000 fast path:** When VID `0x0A41`, `/capture` uses bulk test measure (existing path) without HID passive listen fallback unless unknown VID.
2. **`/learn_trigger`:** Short-circuit when bulk protocol active and trigger already known in `device_config.json`; skip multi-minute HID probe grid for C-7000.
3. **Audit:** Confirm no color math / goals / calibration imports in `sekonic-bridge/`.
4. **Optional pytest:** Mock-mode smoke for `/capture` (200) — not CI gate.
5. **Manual gate:** Document plugin wizard steps in VALIDATION.md (discover → capture → status flags).

## ROADMAP Reconciliation

ROADMAP Phase 4 success criterion #1 originally said "only `/status`, `/measure`, `/discover`". **04-CONTEXT revision** retains `/capture` and `/learn_trigger` for in-plugin setup. Plans follow CONTEXT; ROADMAP updated during planning.

Phase 5 ROADMAP text ("setup UX on console") means **console-driven wizard UI**, not removal of bridge setup endpoints — aligns with D-75.

## Pitfalls

| Pitfall | Mitigation |
|---------|------------|
| Breaking plugin regex parse on `/status` | Add fields only; never remove setup flags |
| Auth breaks setup wizard | Apply auth to all routes; plugin sends key on every `_http_request` |
| Rename breaks Pi deploy scripts | Update all copy lists in setup-pi.sh / build-image.sh |
| CI regression | Re-run pytest after each wave; host lua suite unchanged |
| HID probe removal breaks unknown meters | Gate skip to C-7000 VID only; keep fallback for other VID |

## Skip Research Flag

Standard patterns apply. No additional research-phase spawn needed beyond this document.

## Plan Wave Split

| Wave | Plan | Focus | Requirements |
|------|------|-------|--------------|
| 1 | 04-01 | Bulk rename + MeterBackend + packaging | MTR-02 |
| 2 | 04-02 | API key bridge + plugin + pytest | MTR-08 |
| 3 | 04-03 | Setup internal thinning + validation | MTR-01, MTR-07, D-56 |
