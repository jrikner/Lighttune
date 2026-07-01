# Roadmap: Lighttune (SekonicCalibrator)

## Overview

Brownfield replan: cherry-pick proven commits onto main, keep **one GrandMA3 plugin** with all calibration logic, and a **thin Pi/Arduino HTTP bridge** (USB meter I/O only). Shared tests and CI gate quality; remote measure from FOH; UAT on real hardware.

## Phases

**Phase Numbering:**

- Integer phases (1–7): Planned milestone work
- Decimal phases (e.g. 2.1): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Canonical Merge & Baseline** - Single truthful source tree with aligned docs, version, and config paths
- [ ] **Phase 2: Plugin Hardening & Test Seams** - Single-plugin layout; extract only what host tests require; hardened JSON in-plugin
- [ ] **Phase 3: Shared Test Strategy & CI** - Host Lua tests, bridge pytest, golden fixtures, GitHub workflow
- [ ] **Phase 4: Thin Bridge (Pi/Arduino)** - Minimal HTTP server: USB read, raw JSON return, mock for dev — no calibration logic on device
- [ ] **Phase 5: MA3 ↔ HTTP Integration** - bridge_client, remote measure, setup wizard, auto-loop
- [ ] **Phase 6: Operator UX, Docs & Show Readiness** - v0.4 workflow modularized, patch UX, runbooks
- [ ] **Phase 7: Console UAT & Hardware Validation** - Real MA3 + Pi + C-7000 end-to-end sign-off

## Phase Details

### Phase 1: Canonical Merge & Baseline

**Goal**: Cherry-pick proven commits from experimental/research branches onto main; docs and manifests match reality.
**Depends on**: Nothing (first phase)
**Requirements**: BASE-01, BASE-02, BASE-03
**Success Criteria** (what must be TRUE):

  1. Developer works from main with v0.4 plugin behavior plus cherry-picked bridge + v0.5 HTTP client commits (not a wholesale merge of one conflicting branch)
  2. Cherry-pick manifest documents which commits came from `sekonic-remote-api-research` vs `Lighttune-experimental` and why
  3. README, `plugin.xml`, version strings, and `config.json.example` describe only what the code actually does (no false community-upload or disk-GDTF claims)
  4. `config.json` load path is documented in README and matches the path used by plugin code

**Plans**: 3 plans

Plans:
**Wave 1**

- [ ] 01-01-PLAN.md — Cherry-pick six research commits onto main + manifest (BASE-01)

**Wave 2** *(blocked on Wave 1 completion)*

- [ ] 01-02-PLAN.md — v0.5.0-replan version alignment + README honesty + config path (BASE-02, BASE-03)

**Wave 3** *(blocked on Wave 2 completion)*

- [ ] 01-03-PLAN.md — Verification gate: lua tests, grep audits, tree parity (BASE-01/02/03)

### Phase 2: Plugin Hardening & Test Seams

**Goal**: One MA3 plugin owns calibration intelligence; extract only the minimum needed for host testing (color math duplication eliminated).
**Depends on**: Phase 1
**Requirements**: ARCH-01, ARCH-02, ARCH-03, ARCH-05, DB-01
**Success Criteria** (what must be TRUE):

  1. Plugin remains a **single deployable artifact** (`plugin.xml` → primary Lua entry); no multi-file plugin split unless MA3 `require` is verified necessary
  2. Color math is testable without duplicating logic in `test_color_math.lua` (shared module or verified single source)
  3. Fixture database uses hardened JSON parse/encode inside the plugin with append-only `fixture_log.json` and best-value flags
  4. Goals, assessment, HTTP client, and session orchestration live in the plugin — not on the bridge

**Plans**: TBD

**Research flag**: Only split Lua files if host tests cannot run against a single plugin source; prefer one plugin.

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

### Phase 4: Thin Bridge (Pi/Arduino)

**Goal**: Stage device is transport-only: USB Sekonic read, HTTP JSON response, health status — no calibration or wizard logic on Pi.
**Depends on**: Phase 1 (may parallelize with Phases 2–3 after cherry-picks land)
**Requirements**: MTR-01, MTR-02, MTR-07
**Success Criteria** (what must be TRUE):

  1. Bridge exposes only `/status`, `/measure`, and minimal `/discover` (USB present) on show LAN (default port 8765)
  2. C-7000 read via USB bulk; returns raw `{ cct, duv, cri, r9, tlci? }` — no color math, goals, or SetColor on device
  3. When `bridge_api_key` is set, bridge rejects requests without matching `X-Bridge-Key` header; plugin sends key from `config.json`
  4. Mock mode returns realistic readings for dev without hardware

**Plans**: TBD

### Phase 5: MA3 ↔ HTTP Integration

**Goal**: FOH operator triggers remote C-7000 measurement over HTTP with explicit failure UX and optional auto-loop convergence.
**Depends on**: Phases 2, 3, and 4
**Requirements**: ARCH-04, MTR-03, MTR-04, MTR-05, MTR-06
**Success Criteria** (what must be TRUE):

  1. Plugin calls bridge over LuaSocket HTTP/1.0 with explicit timeouts and parses MeasurementRecord JSON into session state
  2. On bridge failure, operator can retry remote measure, enter values manually, or cancel without losing the session
  3. After successful remote measure, auto-loop runs up to 3 apply/measure cycles using `goals_met()` with operator exit at any point
  4. Bridge Status and setup wizard (discover + test measure) are reachable from the plugin main menu — **all setup UX on console**, not on Pi

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
| 1. Canonical Merge & Baseline | 0/3 | Not started | - |
| 2. Clean Architecture — Domain Modules | 0/TBD | Not started | - |
| 3. Shared Test Strategy & CI | 0/TBD | Not started | - |
| 4. Pi Bridge Production | 0/TBD | Not started | - |
| 5. MA3 ↔ HTTP Integration | 0/TBD | Not started | - |
| 6. Operator UX, Docs & Show Readiness | 0/TBD | Not started | - |
| 7. Console UAT & Hardware Validation | 0/TBD | Not started | - |

---
*Roadmap created: 2026-07-01 — Lighttune replan milestone*
