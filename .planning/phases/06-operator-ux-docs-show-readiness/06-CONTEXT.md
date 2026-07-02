# Phase 6: Operator UX, Docs & Show Readiness - Context

**Gathered:** 2026-07-02
**Status:** Ready for planning
**Source:** Synthesized from ROADMAP.md, REQUIREMENTS.md, STATE.md, ARCHITECTURE.md, Phase 2/5 deferrals (no discuss-phase run)

<domain>
## Phase Boundary

Phase 6 delivers **operator-ready v0.4 calibration workflow** through modular Lua UI/integration layers, plus **deployment documentation with macOS onPC + local bridge as the primary path (TOP-01)**.

**In scope:**
- Extract remaining monolith sections into `config.lua`, `patch_api.lua`, `fixture_apply.lua`, `ui/*`, `calibration.lua` per `.planning/research/ARCHITECTURE.md`
- Verify/preserve existing v0.4 behaviors already inline in `SekonicCalibrator.lua`: session goals, per-group measure→assess→apply loop, session summary, manual meter entry (C-700/C-800/C-7000), history pre-fill, fixture history viewer, patch make/model, capability hints, gel hints, quality assessment
- **macOS runbook first** (install bridge, USB, `127.0.0.1`, verify `/status` + Bridge Status) — TOP-01, UX-05
- **Secondary** Pi stage-split runbook (VLAN, firewall, troubleshooting)
- README/manifest alignment (no false community-upload or disk-GDTF claims)

**Out of scope:**
- Closed-loop correction math (CAL-07 / architecture phase 8) — auto-loop from Phase 5 remains read-only convergence check
- Auto-accept auto-loop without confirmation (Phase 5 D-97 deferral)
- "Configure Bridge" mid-calibration shortcut (Phase 5 deferral)
- HTTPS/TLS, HMAC auth (ADV-01)
- Community fixture DB sync (ADV-02)
- Native meter HTTP transport
- Phase 7 hardware UAT (macOS sign-off happens in Phase 7, but Phase 6 must publish the runbook Phase 7 executes against)

</domain>

<decisions>
## Implementation Decisions

### Topology & docs (TOP-01, UX-05)
- **D-101:** **macOS + GrandMA3 onPC + local `sekonic-bridge` on `127.0.0.1`** is the **default documented deployment** and Phase 6 ship-gate docs priority. Pi is secondary for stage-split only.
- **D-102:** Default `config.json.example` uses `bridge_ip: "127.0.0.1"` (already on product branch); Phase 6 runbook must match.
- **D-103:** macOS runbook section appears **before** Pi VLAN runbook in README and `sekonic-bridge/README.md`.
- **D-104:** macOS runbook covers: Python venv, `pip install -r requirements.txt`, pyusb/libusb setup, `python server.py` (or documented launch), USB plug, curl `/status`, plugin Bridge Status verification.

### Module extraction order (from ARCHITECTURE.md + Phase 2 deferral)
- **D-105:** Wave 1 — `config.lua` (load_config, get_plugin_dir, paths) before UI split.
- **D-106:** Wave 2 — `patch_api.lua` + `fixture_apply.lua` (patch read + SetColor apply) extracted from monolith Sections 3b/4.
- **D-107:** Wave 3 — `ui/*` modules (`dialogs`, `session`, `measurement`, `assessment`, `history`) + `calibration.lua` orchestrator; thin `main.lua` or retained entry with minimal wiring.
- **D-108:** Use existing `load_domain_modules()` pattern (require + loadfile fallback per D-23). Do not break host tests.
- **D-109:** **Behavior preservation, not redesign** — modularization must not change v0.4 operator flows, rating bands, or MessageBox semantics.

### Calibration workflow (CAL-01–06)
- **D-110:** Session goals set once at session start (Kelvin, Duv, CRI/R9/TLCI per meter model, mode, meter type).
- **D-111:** Two modes preserved: calibrate-to-target and match-to-reference group.
- **D-112:** Manual Sekonic entry always available when remote fails or operator chooses Manual (C-700/C-800/C-7000 field sets).
- **D-113:** Session summary with per-group pass/fail against goals at session end.

### Patch & UX (UX-01–04, DB-02–03)
- **D-114:** Auto make/model from MA3 patch with manual fallback.
- **D-115:** Feature hints from patch capabilities (Tint, CTB, CTO, ColorWheel).
- **D-116:** Gel hints per existing rules (wheel / no Tint / extreme Duv).
- **D-117:** Quality assessment screen before apply with broadcast rating bands (unchanged).
- **D-118:** History pre-fill (`find_best_for_fixture`, `apply_historical_prefill`) preserved.
- **D-119:** In-console fixture history viewer preserved (`show_fixture_history`).

### Testing
- **D-120:** Host Lua tests must stay green after each wave (`lua5.4 tests/run.lua`). Add host tests for any new pure helpers (config path logic, parse-only UI helpers if extracted).
- **D-121:** Bridge pytest unchanged unless docs-only; no bridge behavior changes in Phase 6 unless required for macOS runbook accuracy.

### Claude's Discretion
- Exact file names under `ui/` (match ARCHITECTURE.md unless MA3 packaging requires flattening).
- Whether to introduce `lua/main.lua` as entry vs keep `SekonicCalibrator.lua` as thin shell (prefer thin shell if `plugin.xml` already points there).
- Order of ui submodule extraction within Wave 3 (dialogs first recommended).
- macOS libusb install path (Homebrew vs MacPorts) — document what works on Apple Silicon.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture & deferrals
- `.planning/research/ARCHITECTURE.md` — target module layout, layer rules, build order step 6
- `.planning/phases/02-plugin-hardening-test-seams/02-CONTEXT.md` — D-23 loader, UI split deferred to Phase 6
- `.planning/phases/05-ma3-http-integration/05-CONTEXT.md` — Phase 6 deferrals (auto-accept, configure bridge shortcut)

### Requirements & topology
- `.planning/REQUIREMENTS.md` — CAL-01–06, DB-02–03, UX-01–05, TOP-01
- `.planning/ROADMAP.md` — Phase 6 success criteria, macOS priority
- `.planning/STATE.md` — TOP-01 locked decision

### Code (brownfield source of truth)
- `lua/SekonicCalibrator.lua` — monolith Sections 3 (UI), 3b (patch), 4 (apply), 5 (logging), 6 (main/calibration)
- `lua/color_math.lua`, `lua/fixture_db.lua`, `lua/goals.lua` — extracted domain modules (Phase 2)
- `lua/bridge_client.lua` — on `claude/lighttune-main` (Phase 5); planning branch may lag — executor merges/rebases to product branch
- `data/config.json.example` — default `127.0.0.1`
- `README.md`, `sekonic-bridge/README.md` — doc targets

### Testing
- `tests/run.lua` — host test runner
- `.planning/codebase/TESTING.md` — test boundaries

</canonical_refs>

<specifics>
## Specific Ideas

- Phase 5 completed bridge_client on product branch; Phase 6 modularization should treat bridge_client as already extracted — wire through `ui/measurement.lua` not re-inline HTTP.
- v0.4 behaviors largely **already exist** in monolith (~1750 lines post Phase 2); Phase 6 is primarily **refactor + docs**, not greenfield features.
- macOS operator path: same laptop runs onPC + bridge + USB meter — no Pi, no VLAN for primary docs.
- Pi runbook remains for FOH console + stage meter topology.

</specifics>

<deferred>
## Deferred Ideas

- Auto-accept on clean auto-loop reads (Phase 5)
- Configure Bridge shortcut mid-calibration (Phase 5)
- Closed-loop correction math / CAL-07 (future phase)
- HTTPS, HMAC auth, community DB sync
- Windows onPC as blocking ship gate (document only)
- Phase 7 macOS UAT execution (Phase 6 publishes runbook only)

</deferred>

---

*Phase: 06-operator-ux-docs-show-readiness*
*Context gathered: 2026-07-02 — synthesized for planning (discuss-phase optional)*
