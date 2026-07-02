# Lighttune (SekonicCalibrator)

## What This Is

Lighttune is a GrandMA3 plugin that calibrates fixture groups to broadcast-accurate white light using Sekonic spectrometer readings (C-700, C-800, C-7000). It is built for TV and live production crews who need consistent color across fixture groups without leaving the console workflow. v1 adds a **thin HTTP bridge** so a C-7000 can be triggered remotely from the plugin, with manual meter entry retained as fallback.

This GSD milestone **replans from scratch**: one GrandMA3 plugin owns all calibration intelligence; a **local bridge process** (Python `sekonic-bridge`) is **transport-only** between the Sekonic USB port and the console. **Primary deployment: macOS laptop running GrandMA3 onPC with the C-7000 plugged into the same Mac** (`bridge_ip: 127.0.0.1`). A Raspberry Pi on stage remains an optional path when console and meter are on different machines.

## Core Value

**An operator at FOH can calibrate a fixture group in under five minutes with minimal manual typing, while hitting broadcast-grade color targets (CCT, Duv, CRI, R9, TLCI).**

If tradeoffs arise, accuracy targets are not sacrificed for speed—but the default path must be fast (remote measurement, pre-fill from history, auto-loop where safe).

## Requirements

### Validated

- ✓ CCT → xy conversion (Kang et al. 2002) and Duv correction in CIE 1976 u'v' — existing in `lua/SekonicCalibrator.lua`, tested in `test_color_math.lua`
- ✓ Session workflow: goals, meter model selection, per-group inner loop, session summary — existing v0.4
- ✓ Fixture capability hints from MA3 Patch API (Tint, CTB, CTO, ColorWheel) — existing v0.4
- ✓ Append-only fixture database with best-value flags per make/model/kelvin — existing v0.4
- ✓ Manual Sekonic measurement entry (CCT, Duv, CRI, R9, TLCI on C-7000) — existing v0.4
- ✓ Reference-group and target-Kelvin calibration modes — existing v0.4
- ✓ Pi bridge prototype: HTTP API, C-7000 USB bulk driver, mock meter — experimental branches only (not on main)

### Active

- [ ] **Single-plugin architecture**: one MA3 plugin artifact with color math, session UX, fixture DB, goals, and HTTP client — Pi carries no calibration logic
- [ ] **Thin bridge**: Host machine (prefer **macOS onPC laptop**) reads Sekonic over USB and exposes raw MeasurementRecord JSON via HTTP (`/status`, `/measure`); no wizard/business logic on device beyond meter I/O
- [ ] **Primary topology (TOP-01)**: macOS + onPC + local bridge at `127.0.0.1` — no Pi required when console and meter share one machine
- [ ] v1 integration: GrandMA3 plugin + bridge (localhost or show LAN; HTTP, no HTTPS on console)
- [ ] Remote C-7000 measurement from plugin with manual fallback always available
- [ ] Research: MA3 Lua HTTP client options, reliability, timeouts, error UX on real consoles
- [ ] Research: whether Sekonic or other meters expose native HTTP (future topology; v1 uses local/stage bridge)
- [ ] Shared test strategy: color math and DB logic tested once, not duplicated in `test_color_math.lua`
- [ ] Align docs, version, and `plugin.xml` with implementation (no community-upload or GDTF-on-disk false claims)
- [ ] **Lightweight bridge auth**: shared secret (API key header) on `/measure` and `/status` if feasible in MA3 Lua — show LAN + auth defense-in-depth
- [ ] Merge path: **cherry-pick** proven commits from experimental/research branches onto main (not wholesale branch merge)

### Out of Scope

- HTTPS/TLS from GrandMA3 plugin — MA3 runtime constraint; bridge on trusted show LAN only
- Native Sekonic direct HTTP in v1 — deferred pending research (topology option 2); Pi bridge is v1 path
- Automatic GitHub community upload from console — removed from code; local JSON export only
- iOS direct USB to C-7000 — use WebRemote + plugin instead
- Full rewrite discarding all existing color math and UX patterns — we reuse validated behavior

## Context

**Prior work (brownfield):**
- `origin/claude/lighttune-main`: SekonicCalibrator v0.4, manual entry, 126 passing color-math tests
- `origin/claude/sekonic-remote-api-research-HdMTl` / `origin/Lighttune-experimental`: v0.5 plugin + `sekonic-bridge/` (~2.4k lines Python), not merged to main
- Codebase map: `.planning/codebase/` (2026-07-01, multi-branch Sekonic analysis)

**Users:** Lighting programmers and LDs on GrandMA3 in broadcast/theatre environments.

**Environment (primary):** macOS laptop — GrandMA3 onPC + `sekonic-bridge` on `127.0.0.1` + C-7000 USB on the same machine.

**Environment (secondary):** Hardware console at FOH; meter at subject/stage; Pi bridge on show network; Sekonic C-7000 via USB to Pi.

**Topology decision (2026-07-02):** **macOS local bridge is v1 default.** Plugin → HTTP → bridge on USB host. Pi/Arduino only when console and meter are physically separated. Native Sekonic HTTP remains future research.

**Architecture decision (2026-07-01):** Prefer **one plugin** with maximum logic on-console. Bridge is transport-only — trigger measure, return `{ cct, duv, cri, r9, tlci? }`, report connection status. Setup wizard and auto-loop orchestration stay in the plugin.

## Constraints

- **Platform**: GrandMA3 Lua — no `io.popen`, no HTTPS; networking via LuaSocket (TCP HTTP/1.0 pattern validated on experimental branch)
- **Accuracy**: CCT, Duv, CRI, R9, TLCI goals must match broadcast expectations documented in README
- **Speed**: Default calibration path must minimize MessageBox typing (remote measure + history pre-fill)
- **Compatibility**: C-700/C-800 manual path must remain (no TLCI on those meters)
- **Security**: HTTP bridge on private show LAN; no secrets in git; `config.json` local-only
- **Dependencies**: Prior experimental code is reference implementation, not merge-as-is without architectural review

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Single plugin, thin bridge | All calibration intelligence on MA3; bridge host = HTTP + USB meter I/O only | Validated Phases 4–5 |
| **macOS local bridge (TOP-01)** | Same Mac runs onPC + sekonic-bridge; C-7000 USB local; `127.0.0.1` — **primary v1 path**; Pi optional for stage split | **2026-07-02 — priority** |
| Cherry-pick merge (Phase 1) | Take proven commits from experimental branches; avoid wholesale merge of conflicting snapshots | Complete |
| v1 includes plugin + bridge | User priority: minimal typing at FOH with C-7000 | Validated Phase 5 |
| Topology: local Mac first, Pi stage second | No Pi needed when laptop owns USB; Pi for FOH/stage separation | **2026-07-02** |
| Dual core value: speed + accuracy | Both required for broadcast FOH acceptance | — Pending |
| Bridge auth (shared secret) | Simple `X-Bridge-Key` header if MA3 can send it; reject unsigned requests on Pi | — Pending |
| v1 proof = connect + display | First ship gate: plugin↔bridge round-trip and measurement values shown in UI | — Pending |
| Auto-loop: fixed target xy (v1) | Re-apply session goal chromaticity + re-measure until `goals_met`; sufficient if fixtures converge on their own | — Pending |
| Iterative correction math (v2) | Delta-based target adjustment deferred until base connect→measure→display→apply works | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-02 — macOS local bridge elevated to primary topology (TOP-01)*
