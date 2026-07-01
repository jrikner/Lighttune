# Roadmap: Lighttune (SekonicCalibrator)

## Overview

Brownfield replan of GrandMA3 spectrometer calibration: merge experimental branches into one canonical tree, modularize the Lua plugin and Pi bridge, gate quality with shared host/CI tests, wire HTTP remote measure from FOH, polish operator UX and docs, then validate on real console hardware. Seven horizontal layers deliver infrastructure before integration and UAT.

## Phases

**Phase Numbering:**
- Integer phases (1–7): Planned milestone work
- Decimal phases (e.g. 2.1): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Canonical Merge & Baseline** - Single truthful source tree with aligned docs, version, and config paths
- [ ] **Phase 2: Clean Architecture — Domain Modules** - Extract testable color math, fixture DB, and goals from monolith
- [ ] **Phase 3: Shared Test Strategy & CI** - Host Lua tests, bridge pytest, golden fixtures, GitHub workflow
- [ ] **Phase 4: Pi Bridge Production** - Production FastAPI bridge with C-7000 bulk driver and mock dev path
- [ ] **Phase 5: MA3 ↔ HTTP Integration** - bridge_client, remote measure, setup wizard, auto-loop
- [ ] **Phase 6: Operator UX, Docs & Show Readiness** - v0.4 workflow modularized, patch UX, runbooks
- [ ] **Phase 7: Console UAT & Hardware Validation** - Real MA3 + Pi + C-7000 end-to-end sign-off

## Phase Details

### Phase 1: Canonical Merge & Baseline
**Goal**: One canonical branch snapshot merges validated v0.4 plugin behavior with experimental sekonic-bridge; docs and manifests match reality.
**Depends on**: Nothing (first phase)
**Requirements**: BASE-01, BASE-02, BASE-03
**Success Criteria** (what must be TRUE):
  1. Developer can work from a single tree containing v0.4 plugin behavior and the sekonic-bridge folder (research bulk driver reconciled with experimental integration)
  2. README, `plugin.xml`, version strings, and `config.json.example` describe only what the code actually does (no false community-upload or disk-GDTF claims)
  3. `config.json` load path is documented in README and matches the path used by plugin code
**Plans**: TBD

### Phase 2: Clean Architecture — Domain Modules
**Goal**: Domain logic lives in require-able Lua modules so color math, persistence, and goals can be tested without the monolith.
**Depends on**: Phase 1
**Requirements**: ARCH-01, ARCH-02, ARCH-03, ARCH-05, DB-01
**Success Criteria** (what must be TRUE):
  1. Color math runs from `color_math.lua` and is importable by both plugin and host test runner (no duplicated inline math)
  2. Fixture database read/write uses hardened JSON parse/encode with append-only `fixture_log.json` and best-value flags
  3. Goals and quality assessment (`goals_met`, rating bands) are callable without UI or HTTP transport
  4. `main.lua` orchestrates modules; no single 2k-line monolithic source file remains as the entry point
**Plans**: TBD

**Research flag**: Verify MA3 multi-file `require` / `package.path` on target DataVersion 1.6.1.3 before locking module layout.

### Phase 3: Shared Test Strategy & CI
**Goal**: Regressions are caught once on shared modules and bridge routes before feature velocity resumes.
**Depends on**: Phase 2
**Requirements**: TST-01, TST-02, TST-03, TST-04
**Success Criteria** (what must be TRUE):
  1. `lua5.4` host test runner executes against shared modules and preserves 126+ color-math assertions
  2. Bridge `/status`, `/measure`, and `/discover` routes pass pytest/httpx tests against mock meter
  3. Golden JSON fixtures cover bridge MeasurementRecord responses and fixture DB edge cases
  4. CI workflow on push runs host Lua tests and bridge pytest and reports pass/fail
**Plans**: TBD

### Phase 4: Pi Bridge Production
**Goal**: Stage-side bridge is production-ready: correct USB bulk C-7000 driver, discover/measure API, and mock dev path.
**Depends on**: Phase 1 (may parallelize with Phases 2–3 after canonical tree exists)
**Requirements**: MTR-01, MTR-02, MTR-07
**Success Criteria** (what must be TRUE):
  1. Pi bridge serves `/status`, `/measure`, and `/discover` on show LAN (default port 8765)
  2. C-7000 is read via USB bulk protocol (skreader-derived); HID misnomer removed from driver naming and setup flow
  3. `--mock` / MockMeter mode returns realistic improving readings for rehearsal without hardware
**Plans**: TBD

### Phase 5: MA3 ↔ HTTP Integration
**Goal**: FOH operator triggers remote C-7000 measurement over HTTP with explicit failure UX and optional auto-loop convergence.
**Depends on**: Phases 2, 3, and 4
**Requirements**: ARCH-04, MTR-03, MTR-04, MTR-05, MTR-06
**Success Criteria** (what must be TRUE):
  1. Plugin calls bridge over LuaSocket HTTP/1.0 with explicit timeouts and parses MeasurementRecord JSON into session state
  2. On bridge failure, operator can retry remote measure, enter values manually, or cancel without losing the session
  3. After successful remote measure, auto-loop runs up to 3 apply/measure cycles using `goals_met()` with operator exit at any point
  4. Bridge Status and setup wizard (discover + test measure) are reachable from the plugin main menu
**Plans**: TBD

**UI hint**: yes

**Research flag**: Confirm LuaSocket availability, timeout values, and blocking UI behavior on physical MA3 console.

### Phase 6: Operator UX, Docs & Show Readiness
**Goal**: Full v0.4 calibration workflow runs through modular UI with patch integration, history, and honest show-network documentation.
**Depends on**: Phase 5
**Requirements**: CAL-01, CAL-02, CAL-03, CAL-04, CAL-05, CAL-06, DB-02, DB-03, UX-01, UX-02, UX-03, UX-04, UX-05
**Success Criteria** (what must be TRUE):
  1. Operator sets session goals once (Kelvin, Duv, CRI/R9/TLCI, mode, meter model) and completes per-group measure → assess → apply loops with session pass/fail summary
  2. Manual Sekonic entry remains available for C-700, C-800, and C-7000 when remote measure is unavailable
  3. History pre-fill applies best-known correction on group entry; in-console viewer searches fixture log by make/model
  4. Patch-derived make/model, feature hints (Tint, CTB, CTO, ColorWheel), gel hints, and quality assessment screen match v0.4 broadcast rating behavior
  5. Bridge network runbook (VLAN, firewall, troubleshooting) is published and matches plugin setup flows
**Plans**: TBD

**UI hint**: yes

### Phase 7: Console UAT & Hardware Validation
**Goal**: Ship gate — real GrandMA3, Pi bridge, and C-7000 prove the <5-minute remote-measure calibration path.
**Depends on**: Phase 6
**Requirements**: UAT-01, UAT-02, UAT-03
**Success Criteria** (what must be TRUE):
  1. End-to-end calibration session is documented on real GrandMA3 1.6+ with Pi bridge and C-7000 USB meter
  2. `require("socket")` / LuaSocket TCP HTTP works on the target console build used for production
  3. Operator completes one fixture group calibration in under five minutes using the remote measure path with broadcast-grade metric targets met or explicitly accepted
**Plans**: TBD

**Research flag**: TLCI field presence across C-7000 firmware versions; closed-loop correction math if auto-loop convergence is below acceptance threshold.

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 (Phase 4 may start after Phase 1 in parallel with 2–3).

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Canonical Merge & Baseline | 0/TBD | Not started | - |
| 2. Clean Architecture — Domain Modules | 0/TBD | Not started | - |
| 3. Shared Test Strategy & CI | 0/TBD | Not started | - |
| 4. Pi Bridge Production | 0/TBD | Not started | - |
| 5. MA3 ↔ HTTP Integration | 0/TBD | Not started | - |
| 6. Operator UX, Docs & Show Readiness | 0/TBD | Not started | - |
| 7. Console UAT & Hardware Validation | 0/TBD | Not started | - |

---
*Roadmap created: 2026-07-01 — Lighttune replan milestone*
