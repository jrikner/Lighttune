# Roadmap: Lighttune (SekonicCalibrator)

## Overview

Brownfield replan: cherry-pick proven commits onto main, keep **one GrandMA3 plugin** with all calibration logic, and a **thin HTTP bridge** (USB meter I/O only — runs on **macOS alongside onPC** as the **primary** path, or on a Pi when console and meter are physically separated). Shared tests and CI gate quality; remote measure from the console; UAT on real hardware.

## Deployment topology (priority order)

| Priority | Topology | When to use | Bridge address |
|----------|----------|-------------|----------------|
| **1 — Primary** | **macOS + GrandMA3 onPC + local bridge** | Same laptop runs onPC and owns the C-7000 USB port (prep, small shows, single-machine workflow) | `127.0.0.1:8765` |
| 2 — Stage split | Raspberry Pi (or similar) + show LAN | Hardware console at FOH, meter on stage, dedicated transport box | Pi IP on VLAN |
| 3 — Future | Native meter HTTP | If Sekonic documents on-device REST | TBD |

**Important:** The plugin never talks USB directly (MA3 Lua sandbox). The bridge process must run on whichever machine has the Sekonic plugged in — for most solo/small-show use that is the **same Mac** running onPC, not a separate Pi.

```text
[C-7000] ──USB──► [Mac: sekonic-bridge :8765]
                        ▲ HTTP 127.0.0.1
                        │
              [GrandMA3 onPC — same Mac, same showfile]
```

Pi/Arduino remain valid for **stage-split** installs only; they are not required when console and meter share one host.

## Phases

**Phase Numbering:**

- Integer phases (1–7): Planned milestone work
- Decimal phases (e.g. 2.1): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Canonical Merge & Baseline** - Single truthful source tree with aligned docs, version, and config paths
- [ ] **Phase 2: Plugin Hardening & Test Seams** - Single-plugin layout; extract only what host tests require; hardened JSON in-plugin
- [x] **Phase 3: Shared Test Strategy & CI** - Host Lua tests, bridge pytest, golden fixtures, GitHub workflow (2026-07-02)
- [x] **Phase 4: Thin Bridge (Pi/Arduino)** - Minimal HTTP server: USB read, raw JSON return, mock for dev — no calibration logic on device (completed 2026-07-02)
- [x] **Phase 5: MA3 ↔ HTTP Integration** - bridge_client, remote measure, setup wizard, auto-loop (completed 2026-07-02)
- [ ] **Phase 6: Operator UX, Docs & Show Readiness** - v0.4 workflow modularized, patch UX, **macOS onPC runbook (primary)**, Pi stage runbook (secondary)
- [ ] **Phase 7: Console UAT & Hardware Validation** - **macOS onPC + local bridge + C-7000** end-to-end sign-off (Pi topology secondary)

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

- [x] 01-01-PLAN.md — Cherry-pick six research commits onto main + manifest (BASE-01)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 01-02-PLAN.md — v0.5.0-replan version alignment + README honesty + config path (BASE-02, BASE-03)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 01-03-PLAN.md — Verification gate: lua tests, grep audits, tree parity (BASE-01/02/03)

### Phase 2: Plugin Hardening & Test Seams

**Goal**: One MA3 plugin owns calibration intelligence; extract only the minimum needed for host testing (color math duplication eliminated).
**Depends on**: Phase 1
**Requirements**: ARCH-01, ARCH-02, ARCH-03, ARCH-05, DB-01
**Success Criteria** (what must be TRUE):

  1. Plugin remains a **single deployable artifact** (`plugin.xml` → primary Lua entry); no multi-file plugin split unless MA3 `require` is verified necessary
  2. Color math is testable without duplicating logic in `test_color_math.lua` (shared module or verified single source)
  3. Fixture database uses hardened JSON parse/encode inside the plugin with append-only `fixture_log.json` and best-value flags
  4. Goals, assessment, HTTP client, and session orchestration live in the plugin — not on the bridge

**Plans**: 3 plans

Plans:
**Wave 1**

- [x] 02-01-PLAN.md — Extract color_math.lua + module loader + refactor tests to require (ARCH-01, ARCH-05)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 02-02-PLAN.md — Extract fixture_db.lua + JSON hardening + wire monolith (ARCH-02, DB-01)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 02-03-PLAN.md — Extract goals.lua + remove base64 + goals_met tests + verification gate (ARCH-03)

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

**Plans**: 3 plans

Plans:
**Wave 1**

- [x] 03-01-PLAN.md — tests/run.lua + split host tests + root wrapper (TST-01)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 03-02-PLAN.md — Golden fixtures + bridge pytest mock routes (TST-02, TST-03)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 03-03-PLAN.md — GitHub Actions CI workflow (TST-04)

### Phase 4: Thin Bridge (Pi/Arduino)

**Goal**: Stage device is transport-only: USB Sekonic read, HTTP JSON response, health status — no calibration logic on Pi. **In-plugin setup wizard preserved** (`/discover`, `/capture`, `/learn_trigger`).
**Depends on**: Phase 1 (may parallelize with Phases 2–3 after cherry-picks land)
**Requirements**: MTR-01, MTR-02, MTR-07, MTR-08
**Success Criteria** (what must be TRUE):

  1. Bridge serves core routes `/status`, `/measure`, `/discover` plus setup routes `/capture`, `/learn_trigger` for in-plugin wizard on show LAN (default port 8765)
  2. C-7000 read via USB bulk; returns raw `{ cct, duv, cri, r9, tlci? }` — no color math, goals, or SetColor on device
  3. When `bridge_api_key` is set, bridge rejects requests without matching `X-Bridge-Key` header; plugin sends key from `config.json`
  4. Mock mode returns realistic readings for dev without hardware; setup routes succeed in mock mode

**Plans**: 3/3 plans complete

Plans:
**Wave 1**

- [x] 04-01-PLAN.md — Bulk driver rename + MeterBackend + packaging (MTR-02)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 04-02-PLAN.md — API key auth bridge + plugin + pytest (MTR-08)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 04-03-PLAN.md — Setup internal thinning + validation gate (MTR-01, MTR-07, D-75)

### Phase 5: MA3 ↔ HTTP Integration

**Goal**: FOH operator triggers remote C-7000 measurement over HTTP with explicit failure UX and optional auto-loop convergence.
**Depends on**: Phases 2, 3, and 4
**Requirements**: ARCH-04, MTR-03, MTR-04, MTR-05, MTR-06
**Success Criteria** (what must be TRUE):

  1. Plugin calls bridge over LuaSocket HTTP/1.0 with explicit timeouts and parses MeasurementRecord JSON into session state
  2. On bridge failure, operator can retry remote measure, enter values manually, or cancel without losing the session
  3. After successful remote measure, auto-loop runs up to 3 apply/measure cycles using `goals_met()` with operator exit at any point
  4. Bridge Status and setup wizard (discover + test measure) are reachable from the plugin main menu — **all setup UX on console**, not on Pi

**Plans**: 3/3 plans complete

Plans:
**Wave 1**

- [x] 05-01-PLAN.md — Extract bridge_client.lua + domain loader (ARCH-04, MTR-03)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 05-02-PLAN.md — Wire monolith, error UX, C-7000 gate, Bridge Status (MTR-03, MTR-04, MTR-06)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 05-03-PLAN.md — Auto-loop verify + Lua tests + validation (MTR-05)

**UI hint**: yes

### Phase 6: Operator UX, Docs & Show Readiness

**Goal**: Full v0.4 calibration workflow runs through modular UI with patch integration, history, and deployment docs — **macOS + onPC + local bridge documented as the default path**.
**Depends on**: Phase 5
**Requirements**: CAL-01, CAL-02, CAL-03, CAL-04, CAL-05, CAL-06, DB-02, DB-03, UX-01, UX-02, UX-03, UX-04, UX-05, **TOP-01**
**Success Criteria** (what must be TRUE):

  1. **macOS runbook published first**: install `sekonic-bridge` on Mac, plug C-7000 via USB, set `bridge_ip: "127.0.0.1"`, verify `/status` and plugin Bridge Status — no Pi required for this path
  2. Operator sets session goals once (Kelvin, Duv, CRI/R9/TLCI, mode, meter model) and completes per-group measure → assess → apply loops with session pass/fail summary
  3. Manual Sekonic entry remains available for C-700, C-800, and C-7000 when remote measure is unavailable
  4. History pre-fill applies best-known correction on group entry; in-console viewer searches fixture log by make/model
  5. Patch-derived make/model, feature hints (Tint, CTB, CTO, ColorWheel), gel hints, and quality assessment screen match v0.4 broadcast rating behavior
  6. **Secondary** Pi stage runbook (VLAN, firewall, troubleshooting) documented for FOH/stage-split installs

**Plans**: 3 plans

Plans:
**Wave 1**

- [ ] 06-01-PLAN.md — macOS onPC runbook + config.lua + config.json.example fix (TOP-01, UX-05, D-105)

**Wave 2** *(blocked on Wave 1 completion)*

- [ ] 06-02-PLAN.md — goals shadowing fix + patch_api.lua + fixture_apply.lua (UX-01/02, CAL-04, D-106)

**Wave 3** *(blocked on Wave 2 completion)*

- [ ] 06-03-PLAN.md — ui/* + calibration.lua + thin shell + bridge_client merge + validation (CAL-01–03/05–06, DB-02/03, UX-03/04, D-107–D-121)

**UI hint**: yes

**Platform priority**: macOS onPC is the **ship gate default**; Windows onPC and hardware-console + Pi are documented but not blocking v1.

### Phase 7: Console UAT & Hardware Validation

**Goal**: Ship gate — **macOS GrandMA3 onPC + local sekonic-bridge + C-7000 USB** proves the <5-minute remote-measure calibration path. Pi stage topology validated as secondary.
**Depends on**: Phase 6
**Requirements**: UAT-01, UAT-02, UAT-03, **TOP-01**
**Success Criteria** (what must be TRUE):

  1. End-to-end calibration session documented on **macOS** with GrandMA3 onPC 1.6+, `sekonic-bridge` on `127.0.0.1`, and C-7000 on the same Mac via USB (**primary sign-off**)
  2. `require("socket")` / LuaSocket TCP HTTP works on the target onPC build used for production
  3. Operator completes one fixture group calibration in under five minutes using remote measure with broadcast-grade metric targets met or explicitly accepted
  4. *(Secondary)* Pi stage-split topology smoke-tested or documented as optional install path

**Plans**: TBD

**Research flag**: macOS pyusb/libusb permissions and Sekonic USB stability on Apple Silicon; TLCI field presence across C-7000 firmware versions; closed-loop correction math if auto-loop convergence is below acceptance threshold.

**UAT default environment**: Mac laptop — not Pi — unless operator explicitly tests stage-split topology.

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 (Phase 4 may start after Phase 1 in parallel with 2–3).

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Canonical Merge & Baseline | 3/3 | Complete | 2026-07-01 |
| 2. Plugin Hardening & Test Seams | 3/3 | Executed | 2026-07-02 |
| 3. Shared Test Strategy & CI | 3/3 | Complete    | 2026-07-02 |
| 4. Pi Bridge Production | 3/3 | Complete   | 2026-07-02 |
| 5. MA3 ↔ HTTP Integration | 3/3 | Complete   | 2026-07-02 |
| 6. Operator UX, Docs & Show Readiness | 0/3 | Planned | - |
| 7. Console UAT & Hardware Validation | 0/TBD | Not started | - |

---
*Roadmap created: 2026-07-01 — Lighttune replan milestone*
