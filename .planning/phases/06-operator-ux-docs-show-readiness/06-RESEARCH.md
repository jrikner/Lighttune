# Phase 6: Operator UX, Docs & Show Readiness — Research

**Researched:** 2026-07-02  
**Domain:** GrandMA3 v0.4 calibration workflow modularization, patch/history UX preservation, macOS onPC + local bridge deployment docs  
**Confidence:** HIGH for brownfield behavior inventory (monolith grep/read); MEDIUM for MA3 multi-file `require` on console (Phase 7 UAT); MEDIUM for macOS pyusb on Apple Silicon with pinned `pyusb==1.3.1` (Homebrew libusb path varies by Python origin)

## Summary

Phase 6 is primarily **refactor + documentation**, not greenfield features. The v0.4/v0.5 calibration workflow — session goals, per-group measure→assess→apply loop, session summary, manual meter entry, history pre-fill, fixture history viewer, patch make/model, capability hints, gel hints, quality assessment — **already exists inline** in `lua/SekonicCalibrator.lua` (~1,749 lines post Phase 2 extraction) [VERIFIED: function grep and section read].

**Primary recommendation:** Execute in three waves per locked decisions D-105–D-109: (1) `config.lua`, (2) `patch_api.lua` + `fixture_apply.lua`, (3) `ui/*` + `calibration.lua` with thin entry shell; **publish macOS onPC runbook first** (TOP-01, UX-05); fix doc/config drift (`127.0.0.1`, config path, `socket.http` claims); resolve **`goals` module vs session-goals variable shadowing** before modularization ships; merge Phase 5 `bridge_client.lua` from product branch if absent in executor tree [VERIFIED: workspace lacks `lua/bridge_client.lua` and `tests/test_bridge_client.lua`; STATE.md reports Phase 5 complete on product branch].

<user_constraints>
## User Constraints (from CONTEXT.md)

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

### Deferred (OUT OF SCOPE)
- Auto-accept on clean auto-loop reads (Phase 5)
- Configure Bridge shortcut mid-calibration (Phase 5)
- Closed-loop correction math / CAL-07 (future phase)
- HTTPS, HMAC auth, community DB sync
- Phase 7 macOS UAT execution (Phase 6 publishes runbook only)
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Brownfield status | Phase 6 work |
|----|-------------|-------------------|--------------|
| **CAL-01** | Session goals set once (Kelvin, Duv, CRI/R9/TLCI, mode, meter) | **Implemented** — `get_session_goals` L211–290, `get_spectral_goals` L135–197 | Extract to `ui/session.lua`; preserve dialogs |
| **CAL-02** | Two modes: target Kelvin and match-to-reference | **Implemented** — `MODE_TARGET` / `MODE_REFERENCE`, reference flow L237–256 | Preserve in `ui/session.lua` |
| **CAL-03** | Per-group inner loop: measure → assess → apply → re-measure | **Implemented** — inner loop L1544–1702; auto-loop when bridge active | Extract to `calibration.lua`; no UX redesign |
| **CAL-04** | Apply via `SetColor("xyY")` with HSB fallback; preserve brightness | **Implemented** — `calibrate_group` L1338–1347, Y=1.0 | Extract to `fixture_apply.lua` |
| **CAL-05** | Session summary with per-group pass/fail | **Implemented** — `show_session_summary` L695–736 | Extract to `ui/session.lua` or `calibration.lua` |
| **CAL-06** | Manual Sekonic entry always available | **Implemented** — `get_measurement_params` manual path L463–518; bridge fallback | Wire through `ui/measurement.lua` → `bridge_client` |
| **DB-02** | History pre-fill before first measurement | **Implemented** — `apply_historical_prefill` L365–390; main L1518–1537 | Preserve; optional pure helper test for correction pick logic |
| **DB-03** | In-console fixture history viewer | **Implemented** — `show_fixture_history` L739–837 | Extract to `ui/history.lua` |
| **UX-01** | Auto make/model from patch + manual fallback | **Implemented** — `get_fixture_from_patch` L306–330, `get_fixture_model_input` L334–361 | `patch_api.lua` + `ui` caller |
| **UX-02** | Feature-aware hints (Tint, CTB, CTO, ColorWheel) | **Implemented** — `read_capabilities_from_patch` L1229–1310; hints in `show_assessment` L600–612 | Split patch read vs UI display |
| **UX-03** | Conditional gel hints | **Implemented** — `show_assessment` L567–598 uses `caps` + `color_math.gel_hint` | Preserve rules exactly |
| **UX-04** | Quality assessment before apply | **Implemented** — `show_assessment` L540–664 with `QUALITY` bands | Extract to `ui/assessment.lua` |
| **UX-05** | macOS onPC runbook first; Pi second | **GAP** — README Pi-first; no macOS section; `sekonic-bridge/README.md` Pi-only | **Primary deliverable** — new runbook sections |
| **TOP-01** | macOS + onPC + local bridge at `127.0.0.1` | **Partial** — code supports any IP; docs/example wrong | Runbook + `config.json.example` → `127.0.0.1` |
</phase_requirements>

## v0.4 Behavior Inventory vs Gaps

### Already inline in `SekonicCalibrator.lua` [VERIFIED]

| Area | Key symbols | Lines (approx) | REQ coverage |
|------|-------------|----------------|--------------|
| Domain loader | `load_domain_modules` | 18–48 | D-108 |
| Session setup | `get_session_goals`, `get_spectral_goals`, `get_reference_measurements` | 111–290 | CAL-01, CAL-02 |
| Group / fixture ID | `get_group_input`, `get_fixture_from_patch`, `get_fixture_model_input` | 292–361 | UX-01 |
| History pre-fill | `apply_historical_prefill` | 365–390 | DB-02 |
| Measurement | `get_measurement_params` (remote + manual) | 396–519 | CAL-03, CAL-06, MTR-04* |
| Assessment | `show_assessment`, `goals_summary_line` | 521–664 | UX-03, UX-04 |
| Session end | `show_session_summary`, `ask_group_done`, `ask_calibrate_another` | 680–736 | CAL-03, CAL-05 |
| History viewer | `show_fixture_history` | 739–837 | DB-03 |
| Bridge (inline §2c) | `_http_request`, `bridge_fetch_measurement`, `show_bridge_status`, `run_bridge_setup` | 839–1220 | MTR-03/06* (Phase 5) |
| Patch capabilities | `read_capabilities_from_patch` | 1229–1310 | UX-02 |
| Fixture apply | `select_group`, `apply_color_xyY`, `apply_color_hsb`, `calibrate_group` | 1316–1347 | CAL-04 |
| Config / I/O | `get_plugin_dir`, `load_config`, `save_fixture_log_local` | 1364–1447 | BASE-03* |
| Orchestration | `main` calibration loops | 1453–1747 | CAL-03, CAL-05 |

\*MTR-* and BASE-* not Phase 6 requirement IDs but affect wiring.

### Gaps requiring Phase 6 action

| Gap | Severity | Evidence | Remediation |
|-----|----------|----------|-------------|
| Monolith not split per ARCHITECTURE.md | Expected | Only `color_math`, `fixture_db`, `goals` extracted | Waves 1–3 extraction |
| `bridge_client.lua` absent in planning workspace | HIGH | No file; §2c still inline L839+ | Rebase/merge Phase 5 product branch before Wave 3 |
| **`goals` name shadowing** | HIGH | Module `local goals = domain.goals` L53; `main` shadows with session table L1489; `show_assessment` calls `goals.goal_status_str` on session param L546; `goals.goals_met` L1628 | Rename module import to `goal_eval` (or session var to `session_goals`) during extraction |
| macOS runbook missing | HIGH | README L118–134 Pi-only; sekonic-bridge README Pi-first | D-103/D-104 runbook |
| `config.json.example` still `192.168.1.50` | MEDIUM | `data/config.json.example` L6 | Update to `127.0.0.1` per D-102 |
| sekonic-bridge README wrong config path | MEDIUM | `data/config.json` L134–144 vs plugin root in main README | Align to plugin root |
| False `socket.http` / `github_token` in bridge README | MEDIUM | sekonic-bridge/README L15, L149–151 | TCP wording; remove dead config keys |
| Host tests for new modules | LOW | No `test_config.lua` | Add path-logic tests in Wave 1 |
| Console-only verification | Expected | No MA3 in CI | Phase 7 UAT checklist references Phase 6 runbook |

## Optimal Module Extraction Order & Dependencies

### Dependency graph [CITED: `.planning/research/ARCHITECTURE.md` build order step 6]

```text
SekonicCalibrator.lua (thin shell)
  └─ main() wiring only
       ├─ calibration.lua ──┬─ ui/session.lua
       │                      ├─ ui/measurement.lua ── bridge_client.lua (Phase 5)
       │                      ├─ ui/assessment.lua
       │                      ├─ ui/history.lua
       │                      └─ ui/dialogs.lua
       ├─ fixture_apply.lua ── patch_api.lua (caps optional)
       ├─ config.lua
       └─ domain: color_math, fixture_db, goals (existing)

Forbidden: color_math → ui; patch_api → bridge_client
```

### Wave plan (locked D-105–D-109)

| Wave | Modules | Source lines | Depends on | Host-testable additions |
|------|---------|--------------|------------|-------------------------|
| **1** | `config.lua` | `get_sep`, `get_plugin_dir`, `get_data_dir`, `load_config` L1364–1421 | `load_domain_modules` | `normalize_plugin_dir(path, host_os)` pure helper + tests |
| **2** | `patch_api.lua` | `get_fixture_from_patch`, `read_capabilities_from_patch` L306–330, L1229–1310 | config (none strictly) | Optional stub-MA3 harness deferred; console-only |
| **2** | `fixture_apply.lua` | `select_group`, `apply_color_*`, `calibrate_group` L1316–1347 | `color_math` | Console-only |
| **3a** | `ui/dialogs.lua` | `get_number_input`, `show_result`, shared MessageBox helpers L96–109, L666–678 | — | None (MA3) |
| **3b** | `ui/session.lua` | `get_session_goals`, spectral/reference helpers, `goals_summary_line`, `show_session_summary` | `goals`, `color_math` | `goals_summary_line` pure extract + test |
| **3c** | `ui/measurement.lua` | `get_measurement_params` | `bridge_client`, `config`, `ui/dialogs` | None (MA3 + optional mock LAN) |
| **3d** | `ui/assessment.lua` | `show_assessment` | `color_math`, `goals` module (not session table) | None |
| **3e** | `ui/history.lua` | `show_fixture_history` | `fixture_db`, `config` | None |
| **3f** | `calibration.lua` | Outer/inner loops from `main` L1488–1738 | all above | None |
| **Shell** | Keep `SekonicCalibrator.lua` entry | Menu + `pcall` wrapper L1453–1747 | `calibration`, `config` | D-107 discretion: prefer thin shell over `main.lua` rename |

**Recommended ui submodule order within Wave 3:** dialogs → session → measurement → assessment → history → calibration orchestrator (matches call graph; dialogs unblocks all MessageBox flows).

### Loader extension pattern [VERIFIED: L18–48]

Extend `load_domain_modules()` return table:

```lua
return {
    color_math = try_require("color_math"),
    fixture_db = try_require("fixture_db"),
    goals      = try_require("goals"),      -- export as goal_eval at call sites
    config     = try_require("config"),
    -- Wave 3: patch_api, fixture_apply, bridge_client, ui.*, calibration
}
```

`plugin.xml` stays single `ComponentLua` → `lua/SekonicCalibrator.lua` [VERIFIED: ARCHITECTURE.md, D-109].

## macOS sekonic-bridge Deployment Runbook (TOP-01, UX-05)

**Topology:** Same Mac runs GrandMA3 onPC + `sekonic-bridge` + C-7000 USB. Plugin `bridge_ip: "127.0.0.1"`. No Pi, no VLAN for primary path [VERIFIED: ROADMAP.md, PROJECT.md].

### Prerequisites

| Step | Action | Confidence |
|------|--------|------------|
| 1 | macOS 12+ (Monterey or later recommended); Apple Silicon or Intel | [ASSUMED] — pyusb/Homebrew support both |
| 2 | GrandMA3 onPC **v1.6+** installed | [VERIFIED: README.md] |
| 3 | Python **3.10+** (3.12 matches CI) | [VERIFIED: `.github/workflows/ci.yml`] |
| 4 | Homebrew installed; on Apple Silicon use native `/opt/homebrew` brew | [CITED: pyusb #355, Homebrew docs] |
| 5 | Sekonic C-7000 + USB Mini-B cable | [VERIFIED: sekonic-bridge README] |

### Install bridge (macOS primary path)

| Step | Command / action | Confidence | Notes |
|------|------------------|------------|-------|
| 1 | `brew install libusb` | [CITED: pyusb README, Homebrew libusb formula] | Provides backend for pyusb; bottles available for Apple Silicon |
| 2 | `cd /path/to/Lighttune/sekonic-bridge` | [VERIFIED] | Repo path operator-specific |
| 3 | `python3 -m venv venv && source venv/bin/activate` | [VERIFIED: start.sh pattern] | Prefer **Homebrew Python** or **python.org** over pyenv on M1 if `No backend available` occurs [CITED: pyusb #361] |
| 4 | `pip install -r requirements.txt` | [VERIFIED: fastapi 0.115, uvicorn 0.32, pyusb 1.3.1] | Pins in repo |
| 5 | Verify pyusb backend: `python -c "import usb.core; print('pyusb OK')"` | [ASSUMED] | If fails on Apple Silicon + pyenv: `export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib` before python [CITED: pyusb #355, #361]; pyusb ≥1.3.2+ may search `/opt/homebrew` natively [CITED: PR #511 — pinned 1.3.1 may lack fix] |
| 6 | **Mock dev (no USB):** `python server.py --mock --host 127.0.0.1 --port 8765` | [VERIFIED: server.py CLI] | Validates plugin integration without meter |
| 7 | **Real C-7000:** Plug meter via USB; `python server.py --host 127.0.0.1 --port 8765` | [VERIFIED: meter_c7000_hid.py L85–90 macOS skips kernel detach] | Default `--host 0.0.0.0` also works for localhost client; document `127.0.0.1` bind for clarity |
| 8 | Verify: `curl -s http://127.0.0.1:8765/status` | [VERIFIED: bridge routes] | Expect `"connected": true` when USB OK |
| 9 | Optional measure test: `curl -s -X POST http://127.0.0.1:8765/measure` | [VERIFIED] | Mock returns improving series; real ~2–20 s |

### Plugin config (same Mac)

| Step | Action | Confidence |
|------|--------|------------|
| 1 | Copy `data/config.json.example` → **`config.json` at plugin root** (same folder as `plugin.xml`) | [VERIFIED: `load_config` L1407–1410] |
| 2 | Set `"bridge_ip": "127.0.0.1"`, `"bridge_port": 8765` | [VERIFIED: code]; example file **needs update** from `192.168.1.50` |
| 3 | Install plugin folder to `~/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator/` | [VERIFIED: README.md] |
| 4 | GrandMA3 → run plugin → **Bridge Status** → verify connected | [VERIFIED: `show_bridge_status` L971+] |
| 5 | Start Calibration → C-7000 session → Remote Measurement | [VERIFIED: `get_measurement_params` L401+] |

### macOS troubleshooting (document in runbook)

| Symptom | Check | Confidence |
|---------|-------|------------|
| `No backend available` / pyusb import OK but no device | `brew list libusb`; use Homebrew Python; set `DYLD_FALLBACK_LIBRARY_PATH` | [CITED: pyusb issues] |
| Meter not in `system_profiler SPUSBDataType` | Cable, port, meter power | [ASSUMED] |
| `curl` connection refused | Bridge not running; wrong port; firewall blocking non-local bind | [VERIFIED] |
| Bridge Status unreachable from onPC | `bridge_ip` typo; using `data/config.json` wrong path | [VERIFIED: CONCERNS.md] |
| TLCI missing in remote read | Expected on real C-7000 standard NR parse | [VERIFIED: meter_c7000_hid.py L64, bridge README] |

### Secondary: Pi stage-split (after macOS section per D-103)

Keep existing Pi image/setup content; add VLAN/firewall/troubleshooting subsection. Operator sets `bridge_ip` to Pi LAN IP instead of `127.0.0.1` [VERIFIED: current sekonic-bridge/README.md content, reordered].

### macOS paths NOT recommended for runbook

| Approach | Why omit |
|----------|----------|
| Wireshark USB capture on macOS | sekonic-bridge README L293 — requires SIP disable | [VERIFIED] |
| MacPorts instead of Homebrew | Homebrew is de facto for Apple Silicon; MacPorts works but adds doc burden | [ASSUMED] |
| systemd on macOS | Use foreground `server.py` or `launchd` plist as optional advanced note | [ASSUMED] |

## Host-Testable Seams During UI Modularization

### Add in Phase 6 (high value, low risk)

| Seam | Module | Test file | Rationale |
|------|--------|-----------|-----------|
| Plugin dir resolution | `config.lua` | `tests/test_config.lua` | Pure path join from `(base, host_os, sep)` — no MA3 API in helper |
| Config regex parse | `config.lua` | same | Feed fixture JSON strings; assert `bridge_ip`, default port 8765 |
| `goals_summary_line` | `ui/session.lua` or small `session_format.lua` | `tests/test_session_format.lua` | Pure string format from goals table |
| `goal_eval` rename guard | entry shell | grep audit | Prevent session/module shadowing regression |
| Historical pre-fill correction pick | optional pure fn | unit test | `pick_prefill_ref(hist)` — best_duv vs entries[1] logic from L383–384 |

### Keep console-only (do not block CI)

| Module | Reason |
|--------|--------|
| `patch_api.lua` | Requires `DataPool`, `Groups`, `FixtureType` |
| `fixture_apply.lua` | Requires `Cmd`, `SetColor` |
| `ui/*` MessageBox flows | Requires `MessageBox`, `display` |
| `calibration.lua` | Full orchestration |

### Preserve existing seams [VERIFIED]

| Module | Tests | Count |
|--------|-------|-------|
| `color_math.lua` | `tests/test_color_math.lua` | part of 139 PASS |
| `fixture_db.lua` | `tests/test_fixture_db.lua` | same |
| `goals.lua` | `tests/test_goals.lua` | same |
| `bridge_client.lua` (Phase 5) | `tests/test_bridge_client.lua` | 161 PASS on product branch; **missing here** |

### Optional future harness [ASSUMED — not Phase 6 scope unless time]

Stub globals (`MessageBox`, `DataPool`, `Cmd`, `SetColor`) for smoke-loading `calibration.lua` on host — defer unless extraction breaks silently.

## Standard Stack

### Core (unchanged)

| Component | Purpose | Phase 6 touch |
|-----------|---------|---------------|
| GrandMA3 Lua 5.4 + MA3 API | Operator UI, patch, SetColor | Modules call same APIs |
| `lua/color_math.lua`, `fixture_db.lua`, `goals.lua` | Domain | Already extracted |
| `lua/bridge_client.lua` | HTTP transport | Merge from Phase 5; wire `ui/measurement.lua` |
| FastAPI + uvicorn + pyusb bridge | macOS/Pi meter I/O | Docs only (D-121) |
| `tests/run.lua` | Host CI gate | Add config/format tests |

### Documentation deliverables

| Artifact | Priority | Change |
|----------|----------|--------|
| `README.md` | P0 | macOS section before Pi; `127.0.0.1`; remote measure on same Mac |
| `sekonic-bridge/README.md` | P0 | macOS runbook first; fix config path + TCP wording |
| `data/config.json.example` | P0 | `bridge_ip: "127.0.0.1"` |
| `plugin.xml` / Lua header | P2 | Version alignment if runbook references v0.5.0-replan |

## Architecture Patterns

### Pattern 1: Thin entry shell

**What:** `SekonicCalibrator.lua` retains `return main`; loads modules; delegates to `calibration.run(display, deps)`.  
**Why:** Avoids `plugin.xml` churn (D-107); matches Phase 2 D-22 precedent.

### Pattern 2: Session vs module naming

**What:** Import goals module as `goal_eval`; session table as `session_goals`.  
**Why:** Fixes shadowing bug where `goals.goal_status_str` and `goals.goals_met` target wrong table [VERIFIED: L53, L546, L1489, L1628].

### Pattern 3: UI module factory (optional)

**What:** Each `ui/*.lua` exports functions taking `(display, deps)` where `deps = { config, bridge_client, color_math, goal_eval, fixture_db, patch_api, fixture_apply }`.  
**Why:** Explicit dependency injection; eases host stubbing later.

### Pattern 4: Behavior preservation checkpoints

After each wave:

1. `lua5.4 tests/run.lua` green (D-120)
2. Grep: no duplicate function bodies in shell (mechanical extraction)
3. Manual diff: MessageBox button labels unchanged (D-109)

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| macOS USB stack | Custom IOKit driver | pyusb + libusb via Homebrew | Proven in bridge |
| JSON config parser | Full decoder in Phase 6 | Keep regex `load_config` in `config.lua` | MA3 constraint; move only |
| New calibration UX | Redesign assessment bands | Copy existing `show_assessment` strings | D-109 |
| Pi-only docs | Rewrite bridge | Reorder + add macOS section | TOP-01 |
| Closed-loop math | Fix `get_correction` loop | Defer CAL-07 Phase 8 | Out of scope |

## Common Pitfalls

### Pitfall 1: Breaking auto-loop when splitting `main`
**What goes wrong:** `MAX_AUTO_ATTEMPTS`, `user_manual`, `bridge_active` flags scattered or reordered.  
**How to avoid:** Extract inner loop as single function with same local names; grep for `MAX_AUTO_ATTEMPTS = 3`.  
**Warning signs:** Auto-loop triggers on manual-only sessions or skips stuck dialog.

### Pitfall 2: `bridge_client` vs inline §2c drift
**What goes wrong:** Planning branch still uses inline HTTP while docs reference module API.  
**How to avoid:** Merge Phase 5 before Wave 3; delete §2c from monolith after wire-up.  
**Warning signs:** Duplicate `_http_request` definitions.

### Pitfall 3: Documenting wrong config path
**What goes wrong:** Operators paste secrets into `data/config.json`; bridge never connects.  
**How to avoid:** Every doc instance: plugin root `config.json`; grep audit both READMEs.  
**Warning signs:** sekonic-bridge README `data/config.json` path [VERIFIED: L134–144].

### Pitfall 4: pyusb on Apple Silicon with pyenv
**What goes wrong:** `No backend available` despite `brew install libusb`.  
**How to avoid:** Runbook recommends Homebrew Python or `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib`.  
**Warning signs:** CI passes (Linux) but macOS laptop fails.

### Pitfall 5: Renaming MessageBox buttons during extraction
**What goes wrong:** Operator muscle memory breaks; UAT scripts fail.  
**How to avoid:** D-109 — copy strings verbatim; use diff tool on UI modules.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| **Host framework** | Lua 5.4 + `tests/lib_assert.lua` |
| **Entry** | `lua5.4 tests/run.lua` |
| **Bridge framework** | pytest + httpx (`tests/test_bridge_routes.py`) |
| **CI** | `.github/workflows/ci.yml` — both jobs on push |
| **Current host count** | **139 passed, 0 failed** [VERIFIED: 2026-07-02 run] |
| **Product branch count** | 161+ with `test_bridge_client.lua` [CITED: Phase 5 SUMMARY] |
| **Console UAT** | Phase 7 — macOS runbook from Phase 6 |

### Phase Requirements → Test Map (Nyquist)

| Req ID | Behavior | Test type | Automated command | Exists? |
|--------|----------|-----------|-------------------|---------|
| CAL-01 | Session goals structure (meter, mode, cct, spectral goals) | console | Phase 7 UAT script | ❌ manual |
| CAL-02 | Reference vs target mode branching | console | Phase 7 UAT | ❌ manual |
| CAL-03 | Inner loop + ask_group_done / auto-loop | console + grep | `grep -n 'MAX_AUTO_ATTEMPTS = 3' lua/calibration.lua` post-extract | ⚠️ grep only |
| CAL-04 | xyY then HSB fallback | console | Phase 7 SetColor smoke | ❌ manual |
| CAL-05 | Session summary pass/fail lines | unit (partial) | extract `session_summary_format` test | ❌ add optional |
| CAL-06 | Manual entry field sets C-700 vs C-7000 | console | Phase 7 UAT | ❌ manual |
| DB-02 | Pre-fill uses best_duv correction | unit | test `pick_prefill_ref` if extracted | ❌ optional |
| DB-02 | find_best_for_fixture wired | unit | `tests/test_fixture_db.lua` | ✅ |
| DB-03 | History search + kelvin grouping | console | Phase 7 UAT | ❌ manual |
| UX-01 | Patch make/model detect | console | Phase 7 with patched showfile | ❌ manual |
| UX-02 | Tint/CTB/CTO/ColorWheel hints | console | Phase 7 assessment screen | ❌ manual |
| UX-03 | Gel hint conditions | unit | `color_math.gel_hint` + assessment rules grep | ✅ partial |
| UX-04 | QUALITY rating bands | unit | `tests/test_color_math.lua` rate_* | ✅ |
| UX-05 | macOS runbook present first | doc grep | `grep -n '127.0.0.1' README.md sekonic-bridge/README.md` | ❌ pre-Phase 6 |
| TOP-01 | localhost bridge topology documented | doc grep | `grep -n 'macOS' README.md`; example IP | ❌ pre-Phase 6 |
| D-120 | Host tests green each wave | regression | `lua5.4 tests/run.lua` | ✅ |
| D-121 | Bridge pytest unchanged | regression | `pytest tests/test_bridge_routes.py -v` | ✅ |

### Sampling rate

- **After every extraction commit:** `lua5.4 tests/run.lua`
- **After Wave 1:** new `tests/test_config.lua` if helpers added
- **After Wave 3:** grep no `local function get_session_goals` in entry shell
- **Before Phase 6 sign-off:** doc grep audit + mock bridge curl + onPC smoke (Phase 7 formal)

### Wave 0 Gaps (must close during Phase 6)

- [ ] Fix `goals` / `session_goals` shadowing before shipping assessment/auto-loop
- [ ] Merge `bridge_client.lua` + `tests/test_bridge_client.lua` from product branch if executor tree lacks them
- [ ] Update `config.json.example` to `127.0.0.1`
- [ ] Add macOS runbook sections (TOP-01, UX-05)
- [ ] Fix sekonic-bridge README: config path, remove `github_token`/`community_upload`, replace `socket.http` with TCP
- [ ] Add `tests/test_config.lua` (or equivalent) for path/parse helpers
- [ ] MA3 `require` for nested `ui/*` — verify on console in Phase 7; keep `loadfile` fallback

## Function → Module Migration Map

| Current symbol | Target module |
|----------------|---------------|
| `get_sep`, `get_plugin_dir`, `get_data_dir`, `load_config` | `config.lua` |
| `get_fixture_from_patch`, `read_capabilities_from_patch` | `patch_api.lua` |
| `select_group`, `apply_color_xyY`, `apply_color_hsb`, `calibrate_group` | `fixture_apply.lua` |
| `get_number_input`, `show_result` | `ui/dialogs.lua` |
| `get_session_goals`, `get_spectral_goals`, `get_reference_measurements`, `goals_summary_line`, `show_session_summary` | `ui/session.lua` |
| `get_measurement_params` | `ui/measurement.lua` |
| `show_assessment` | `ui/assessment.lua` |
| `show_fixture_history` | `ui/history.lua` |
| `get_group_input`, `get_fixture_model_input`, `apply_historical_prefill`, `ask_*`, calibration loops | `calibration.lua` + ui |
| `save_fixture_log_local`, `log_fixture_data` | stay in shell or `config.lua` I/O section |
| §2c bridge HTTP | `bridge_client.lua` (Phase 5) |
| `main` menu + error wrapper | thin `SekonicCalibrator.lua` |

**Estimated shell size post-extraction:** ~150–250 lines (loader + menu + delegate) [ASSUMED based on Phase 2 reduction math].

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| MA3 `require("ui.dialogs")` path failure | HIGH | `loadfile` fallback per D-23; flat `ui_dialogs.lua` escape hatch |
| Behavior drift during extraction | HIGH | D-109; wave-by-wave grep; no string edits in assessment |
| goals shadowing runtime error on console | HIGH | Rename before Phase 6 sign-off |
| macOS pyusb backend missing | MEDIUM | Runbook Homebrew libusb + Python origin guidance |
| Doc/runbook stale vs code | MEDIUM | Single source: `config.json.example` + grep CI check |
| Phase 5 / Phase 6 branch skew | MEDIUM | Executor rebases to product branch before Wave 3 |

## Open Questions (resolved for planning)

| Question | Resolution |
|----------|------------|
| Greenfield vs refactor? | **Refactor + docs** — behaviors exist inline |
| `main.lua` rename? | **No** — thin `SekonicCalibrator.lua` per D-107 discretion |
| macOS bind address? | Document `--host 127.0.0.1`; plugin uses `127.0.0.1` in config |
| libusb via MacPorts? | **Homebrew primary** in runbook; MacPorts footnote optional |
| Closed-loop correction in auto-loop? | **Out of scope** — CAL-07 Phase 8 |

## Sources

### Primary (HIGH confidence)
- `lua/SekonicCalibrator.lua` — full section grep and targeted reads
- `.planning/phases/06-operator-ux-docs-show-readiness/06-CONTEXT.md`
- `.planning/REQUIREMENTS.md`, `ROADMAP.md`, `STATE.md`
- `.planning/research/ARCHITECTURE.md` — module layout, build order step 6
- `data/config.json.example`, `README.md`, `sekonic-bridge/README.md`
- `tests/run.lua` — 139 PASS baseline

### Secondary (MEDIUM confidence)
- [pyusb README — macOS libusb via Homebrew](https://github.com/pyusb/pyusb/) [CITED]
- [Homebrew libusb formula](https://formulae.brew.sh/formula/libusb) [CITED]
- [pyusb PR #511 — Apple Silicon /opt/homebrew search](https://github.com/pyusb/pyusb/pull/511) [CITED]
- [pyusb issue #361 — pyenv M1 backend path](https://github.com/pyusb/pyusb/issues/361) [CITED]
- Phase 5 SUMMARY — `bridge_client.lua` on product branch [CITED]
- `.planning/codebase/CONCERNS.md` — config path, socket.http doc drift [VERIFIED]

---

*Phase: 06-operator-ux-docs-show-readiness*  
*Research complete: 2026-07-02*
