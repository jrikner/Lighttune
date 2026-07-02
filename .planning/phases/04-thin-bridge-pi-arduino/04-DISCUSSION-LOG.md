# Phase 4: Thin Bridge (Pi/Arduino) - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-02
**Phase:** 4-thin-bridge-pi-arduino
**Areas discussed:** Setup endpoint fate, /status JSON shape, API key auth, USB driver refactor, Pi packaging scope, Arduino scope

**Revision (2026-07-02):** User requested in-plugin setup remain for base version — D-55–D-60, D-75–D-76 updated in CONTEXT.md.

---

## 1. Setup endpoint fate

| Option | Description | Selected |
|--------|-------------|----------|
| Delete routes | Remove `/capture` and `/learn_trigger` from server.py | (initial) |
| **Retain routes** | Keep full plugin wizard HTTP surface | ✓ **revised** |
| 410 Gone stubs | Return structured error pointing to console wizard | |
| Dev-only hidden | Keep undocumented for Pi debugging | |

**User's choice (revised):** **Retain** `/capture`, `/learn_trigger`, and plugin `run_bridge_setup` flow (D-55–D-57, D-75)  
**Notes:** "Thin bridge" = no calibration on Pi, not removal of operator setup from plugin.

---

## 2. `/status` JSON shape after thinning

| Option | Description | Selected |
|--------|-------------|----------|
| Slim contract | Drop setup flags; add `auth_required` | (initial) |
| **Keep flags + add auth** | Retain device_configured/protocol_captured/trigger_discovered; add auth_required | ✓ **revised** |
| Minimal ping | Only `status` + `connected` | |

**User's choice (revised):** **Keep existing setup flags**; add `auth_required` when key configured (D-58–D-60)

---

## 3. API key auth (MTR-08)

| Option | Description | Selected |
|--------|-------------|----------|
| X-Bridge-Key, all routes, optional when unset | ROADMAP-aligned | ✓ |
| Measure-only auth | Protect POST /measure only | |
| Bearer token | Authorization: Bearer header | |

**User's choice:** **X-Bridge-Key on all routes including setup**; env + bridge_config.json; plugin sends header on every `_http_request` (D-61–D-65)  
**Notes:** Open LAN when key unset preserves current show-network model.

---

## 4. USB driver refactor (MTR-02)

| Option | Description | Selected |
|--------|-------------|----------|
| Rename + MeterBackend protocol | meter_c7000_bulk.py, shared interface | ✓ |
| Rename only | File/import rename, no abstraction | |
| Full rewrite | New driver from scratch | |

**User's choice:** **Rename + thin MeterBackend** (D-66–D-69)  
**Notes:** CONCERNS.md documents HID misnomer; skreader bulk protocol already implemented.

---

## 5. Pi packaging vs code-only

| Option | Description | Selected |
|--------|-------------|----------|
| Code + script path updates | setup-pi.sh, systemd, build-image import fixes | ✓ |
| Code only | No packaging file touches | |
| Full image/runbook | systemd, udev, firewall docs in Phase 4 | |

**User's choice:** **Code + script path updates**; defer runbook to Phase 6 (D-70–D-72)

---

## 6. Arduino in scope?

| Option | Description | Selected |
|--------|-------------|----------|
| Pi only | Arduino deferred to v2 | ✓ |
| Pi + Arduino stub | Document protocol, no firmware | |
| Dual target Phase 4 | Implement both transports | |

**User's choice:** **Pi only** (D-73)

---

## Claude's Discretion

- FastAPI middleware vs dependency for API key enforcement
- Env-only vs bridge_config.json if systemd prefers Environment= directive
- Migration of stale device_config.json wizard fields

## Deferred Ideas

- Enhanced setup UX (not removal) — Phase 5 may improve
- TLS on bridge — future
- Arduino transport — v2
- Wireshark capture path for unknown meters — optional dev, not replacing plugin wizard
