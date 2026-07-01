# Requirements: Lighttune (SekonicCalibrator)

**Defined:** 2026-07-01  
**Core Value:** An operator at FOH can calibrate a fixture group in under five minutes with minimal manual typing, while hitting broadcast-grade color targets (CCT, Duv, CRI, R9, TLCI).

## v1 Requirements

### Canonical baseline & docs

- [ ] **BASE-01**: Single canonical source tree merges validated v0.4 plugin behavior with experimental sekonic-bridge (reconciled research vs experimental branches)
- [ ] **BASE-02**: README, `plugin.xml`, version strings, and `config.json.example` match implementation (no false community-upload or disk-GDTF claims)
- [ ] **BASE-03**: `config.json` path documented and consistent between README and plugin code

### Architecture & domain modules

- [ ] **ARCH-01**: Color math extracted to testable Lua module (`color_math.lua`) shared by plugin and host tests
- [ ] **ARCH-02**: Fixture database logic extracted to module with hardened JSON parse/encode (not regex-only)
- [ ] **ARCH-03**: Goals and quality assessment logic isolated from UI and transport layers
- [ ] **ARCH-04**: Bridge HTTP client extracted to `bridge_client.lua` with explicit timeouts and error types
- [ ] **ARCH-05**: Plugin entry point (`main.lua`) orchestrates modules; no monolithic 2k-line single file

### Calibration workflow (table stakes)

- [ ] **CAL-01**: Session goals set once (Kelvin, Duv, CRI/R9/TLCI goals, calibration mode, meter model)
- [ ] **CAL-02**: Two modes: calibrate to target Kelvin and match to reference group
- [ ] **CAL-03**: Per-group inner loop: measure → assess → apply → re-measure until operator accepts
- [ ] **CAL-04**: Apply correction via `SetColor("xyY")` with HSB fallback; preserve brightness
- [ ] **CAL-05**: Session summary with per-group pass/fail against goals
- [ ] **CAL-06**: Manual Sekonic entry always available (C-700/C-800/C-7000 field sets)

### Meter & bridge integration

- [ ] **MTR-01**: Pi bridge serves `/status`, `/measure`, `/discover` on show LAN (default port 8765)
- [ ] **MTR-02**: C-7000 USB bulk driver on Pi (skreader-derived protocol); renamed/refactored from HID misnomer
- [ ] **MTR-03**: Plugin triggers remote measurement over HTTP/1.0 (LuaSocket TCP); parses MeasurementRecord JSON
- [ ] **MTR-04**: Remote measure UI: retry, enter manually, or cancel on bridge failure
- [ ] **MTR-05**: Auto-loop after remote measure (max 3 cycles) using `goals_met()` with operator exit
- [ ] **MTR-06**: Bridge Status and setup wizard reachable from plugin main menu
- [ ] **MTR-07**: Mock meter mode for dev (`--mock` / MockMeter) with realistic improving readings

### Fixture database & history

- [ ] **DB-01**: Append-only `fixture_log.json` with best-value flags per make/model/kelvin
- [ ] **DB-02**: History pre-fill applies best-known correction before first measurement on a group
- [ ] **DB-03**: In-console fixture history viewer (search by make/model)

### Operator UX & patch integration

- [ ] **UX-01**: Auto make/model from MA3 patch with manual fallback
- [ ] **UX-02**: Feature-aware hints (Tint, CTB, CTO, ColorWheel) from Patch API
- [ ] **UX-03**: Conditional gel hints per existing rules (wheel / no Tint / extreme Duv)
- [ ] **UX-04**: Quality assessment screen before apply with broadcast rating bands
- [ ] **UX-05**: Bridge network runbook in docs (VLAN, firewall, troubleshooting)

### Testing & quality gates

- [ ] **TST-01**: Host tests run via `lua5.4` against shared modules (126+ color-math assertions preserved)
- [ ] **TST-02**: Bridge route tests via pytest/httpx against mock meter
- [ ] **TST-03**: Golden JSON fixtures for bridge responses and fixture DB edge cases
- [ ] **TST-04**: CI workflow runs host Lua tests and bridge pytest on push

### Hardware validation

- [ ] **UAT-01**: End-to-end validated on real GrandMA3 1.6+ with Pi bridge and C-7000
- [ ] **UAT-02**: `require("socket")` / LuaSocket TCP verified on target console build
- [ ] **UAT-03**: Operator completes one fixture group calibration in under five minutes using remote measure path

## v2 Requirements

Deferred to future release.

### Direct device HTTP

- **HTTP-01**: Research and prototype native Sekonic (or other meter) HTTP API if commercially available
- **HTTP-02**: Pluggable transport layer (Pi bridge vs direct device) behind same MeasurementRecord contract

### Advanced features

- **ADV-01**: Optional bridge authentication (HMAC or token) for stricter show IT policies
- **ADV-02**: Community fixture database sync (manual export remains v1; automated sync deferred)
- **ADV-03**: TM-30 / TLMF / flicker metrics beyond TLCI

## Out of Scope

| Feature | Reason |
|---------|--------|
| HTTPS/TLS from MA3 plugin | Platform constraint; trusted show LAN only |
| Native Sekonic HTTP in v1 | Topology 2: Pi bridge now; direct device research deferred |
| GitHub auto-upload from console | No HTTPS/shell; local JSON export only |
| iOS USB to C-7000 | Use WebRemote + plugin at FOH |
| Full rewrite discarding v0.4 math/UX | Brownfield replan reuses validated behavior |
| Emitter-level GDTF per-LED calibration | Out of plugin scope; MA3 GDTF Builder domain |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| BASE-01 | Phase 1 | Pending |
| BASE-02 | Phase 1 | Pending |
| BASE-03 | Phase 1 | Pending |
| ARCH-01 | Phase 2 | Pending |
| ARCH-02 | Phase 2 | Pending |
| ARCH-03 | Phase 2 | Pending |
| ARCH-04 | Phase 5 | Pending |
| ARCH-05 | Phase 2 | Pending |
| CAL-01 | Phase 6 | Pending |
| CAL-02 | Phase 6 | Pending |
| CAL-03 | Phase 6 | Pending |
| CAL-04 | Phase 6 | Pending |
| CAL-05 | Phase 6 | Pending |
| CAL-06 | Phase 6 | Pending |
| MTR-01 | Phase 4 | Pending |
| MTR-02 | Phase 4 | Pending |
| MTR-03 | Phase 5 | Pending |
| MTR-04 | Phase 5 | Pending |
| MTR-05 | Phase 5 | Pending |
| MTR-06 | Phase 5 | Pending |
| MTR-07 | Phase 4 | Pending |
| DB-01 | Phase 2 | Pending |
| DB-02 | Phase 6 | Pending |
| DB-03 | Phase 6 | Pending |
| UX-01 | Phase 6 | Pending |
| UX-02 | Phase 6 | Pending |
| UX-03 | Phase 6 | Pending |
| UX-04 | Phase 6 | Pending |
| UX-05 | Phase 6 | Pending |
| TST-01 | Phase 3 | Pending |
| TST-02 | Phase 3 | Pending |
| TST-03 | Phase 3 | Pending |
| TST-04 | Phase 3 | Pending |
| UAT-01 | Phase 7 | Pending |
| UAT-02 | Phase 7 | Pending |
| UAT-03 | Phase 7 | Pending |

**Coverage:**
- v1 requirements: 35 total
- Mapped to phases: 35
- Unmapped: 0

---
*Requirements defined: 2026-07-01*  
*Last updated: 2026-07-01 after roadmap creation (pending roadmapper)*
