# Lighttune (SekonicCalibrator)

## What This Is

Lighttune is a GrandMA3 plugin that calibrates fixture groups to broadcast-accurate white light using Sekonic spectrometer readings (C-700, C-800, C-7000). It is built for TV and live production crews who need consistent color across fixture groups without leaving the console workflow. v1 adds a Raspberry Pi bridge so a C-7000 on stage can be triggered over HTTP from FOH, with manual meter entry retained as fallback.

This GSD milestone **replans from scratch**: one GrandMA3 plugin owns all calibration intelligence; the Pi (or Arduino-class device) is a **thin HTTP transport** between the Sekonic meter and the console. Reuses proven color math and workflows from prior experiments (v0.4 main, v0.5 + sekonic-bridge on feature branches).

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
- [ ] **Thin bridge**: Pi/Arduino only reads Sekonic over USB and exposes raw MeasurementRecord JSON via HTTP (`/status`, `/measure`); no wizard/business logic on device beyond meter I/O
- [ ] v1 integration: GrandMA3 plugin + bridge on show LAN (HTTP, no HTTPS on console)
- [ ] Remote C-7000 measurement from plugin with manual fallback always available
- [ ] Research: MA3 Lua HTTP client options, reliability, timeouts, error UX on real consoles
- [ ] Research: whether Sekonic or other meters expose native HTTP (future topology; v1 stays Pi bridge)
- [ ] Shared test strategy: color math and DB logic tested once, not duplicated in `test_color_math.lua`
- [ ] Align docs, version, and `plugin.xml` with implementation (no community-upload or GDTF-on-disk false claims)
- [ ] Production-ready bridge: setup, discovery, mock dev path, operator-facing status in plugin
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

**Environment:** Console at FOH; meter at subject/stage; Pi bridge on show network; Sekonic C-7000 via USB to Pi.

**Topology decision:** v1 = thin bridge (C-7000 → USB → Pi/Arduino → HTTP → plugin). All calibration decisions live on the console. Research whether direct device HTTP exists for future versions.

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
| Single plugin, thin bridge | All calibration intelligence on MA3; Pi/Arduino = HTTP + USB meter I/O only | — Pending |
| Cherry-pick merge (Phase 1) | Take proven commits from experimental branches; avoid wholesale merge of conflicting snapshots | — Pending |
| v1 includes plugin + bridge | User priority: minimal typing at FOH with C-7000 | — Pending |
| Topology 2: Pi bridge now, research direct HTTP later | Pragmatic v1; leave door open for native device APIs | — Pending |
| Dual core value: speed + accuracy | Both required for broadcast FOH acceptance | — Pending |
| GSD replan from scratch | Prior ad-hoc merges and doc drift; structured phase delivery | — Pending |

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
*Last updated: 2026-07-01 after architecture & merge strategy refinement*
