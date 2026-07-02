# Phase 7 — Console UAT & Hardware Validation (Research)
**Phase:** 7 — Console UAT & Hardware Validation  
**Output:** `.planning/phases/07-console-uat-hardware-validation/07-RESEARCH.md`  
**Researched:** 2026-07-02  
**Confidence:** MEDIUM (UAT is hardware/onPC dependent; checklist is codebase-driven)

<user_constraints>
## User constraints (copied from `07-CONTEXT.md`)

### Constraints

- **Platform**: GrandMA3 Lua — no `io.popen`, no HTTPS; networking via LuaSocket (TCP HTTP/1.0 pattern validated on experimental branch)
- **Accuracy**: CCT, Duv, CRI, R9, TLCI goals must match broadcast expectations documented in README
- **Speed**: Default calibration path must minimize MessageBox typing (remote measure + history pre-fill)
- **Compatibility**: C-700/C-800 manual path must remain (no TLCI on those meters)
- **Security**: HTTP bridge on private show LAN; no secrets in git; `config.json` local-only
- **Dependencies**: Prior experimental code is reference implementation, not merge-as-is without architectural review

### Phase boundary (scope)

Phase 7 is the **ship gate** for Lighttune v1. It validates the full operator workflow **end-to-end on real GrandMA3 onPC** with real bridge networking and (ideally) real C-7000 hardware. The **primary topology (TOP-01)** is a single macOS laptop running GrandMA3 onPC (v1.6+), `sekonic-bridge` on `127.0.0.1:8765`, and a Sekonic C-7000 connected via USB to the same Mac.

In scope:
- A reproducible **UAT checklist** (commands + expected UI states) that proves UAT-01/02/03 + TOP-01
- Evidence capture conventions: what screenshots/logs to save, what values to record (time-to-complete, key measurement values)
- Verify the plugin’s LuaSocket TCP HTTP client works on the production onPC build (UAT-02)
- Validate remote measurement UX and values shown to operator (UAT-03)
- Validate a full single-group calibration can complete in under 5 minutes (or document blocker + explicit acceptance override) (UAT-01)

Out of scope:
- New feature work / refactors
- Closed-loop correction algorithm redesign (CAL-07) — Phase 7 records evidence and follows up; it does not silently change algorithms
- Security hardening beyond existing `bridge_api_key` behavior
</user_constraints>

<phase_requirements>
## Phase requirements coverage

| ID | Requirement | What Phase 7 must prove (minimal) |
|----|------------|------------------------------------|
| TOP-01 | Primary path is macOS + onPC + local bridge `127.0.0.1:8765` | UAT executed with bridge on localhost; artifacts reference localhost endpoints and config |
| UAT-01 | End-to-end validated on macOS onPC 1.6+ with localhost bridge + C-7000 USB | One full group session completed; bridge is real (not mock) when hardware available; fallback documented if not |
| UAT-02 | `require("socket")` / LuaSocket TCP verified on target onPC build | Deterministic onPC-visible indicator for LuaSocket availability (see checklist step A2) |
| UAT-03 | Operator triggers remote measure; sees CCT/Duv/CRI/R9/TLCI in plugin UI | Screenshot/video shows remote measure dialog + received values dialog including TLCI when present |
</phase_requirements>

## Research answers

### 1) Minimal, reproducible UAT checklist proving UAT-01/02/03 + TOP-01

This checklist is intentionally “minimal” (ship gate), but still reproducible and evidence-backed. It also subsumes the Phase 5 deferred UAT items that matter for Phase 7 (Bridge Status, remote offer gate, remote measure flow, error flow, auto-loop confirm/stuck). (`.planning/phases/05-ma3-http-integration/05-UAT.md`.)

#### Preconditions (one-time)

- **GrandMA3 onPC** installed and running on macOS (v1.6+ per requirement docs). [ASSUMED]
- **Plugin installed** in the onPC plugin library per `README.md` install instructions. (`README.md`.)
- **Config file** exists at plugin root as `config.json` (same directory as `plugin.xml`) and contains:
  - `bridge_ip` = `"127.0.0.1"`
  - `bridge_port` = `8765`
  - (optional) `bridge_api_key` when bridge auth is enabled (see Risk R4). [ASSUMED]

#### A. Bridge bring-up (TOP-01 proof)

**A1 — Start bridge in mock mode (networking-only smoke test)**
- Terminal:
  - `cd sekonic-bridge`
  - `python3 server.py --mock --port 8765`
- Terminal:
  - `curl http://127.0.0.1:8765/status`
- Expected:
  - `curl` returns JSON including `"status": "ok"`. (`sekonic-bridge/README.md` shows the expected shape; exact fields may vary by implementation.)
- Evidence:
  - Save terminal output to `.planning/phases/07-console-uat-hardware-validation/evidence/<run_id>/bridge_status_mock.txt`.

**A2 — Deterministic LuaSocket TCP indicator on onPC (UAT-02 proof)**
- In GrandMA3 onPC, run plugin → start a calibration session → at the first measurement dialog choose **Remote Measurement**.
- Expected on success path:
  - If the bridge is running, remote returns values and the plugin shows **“Measurement Received”** with **CCT/Duv/CRI/R9** (and TLCI if included). (`lua/SekonicCalibrator.lua` `get_measurement_params()` and `bridge_fetch_measurement()`.)
- Expected deterministic failure modes:
  - If LuaSocket is **missing** on that onPC build: the error dialog shows `Error: luasocket_unavailable`. (`lua/SekonicCalibrator.lua` `_http_request()` returns `"luasocket_unavailable"`.)
  - If LuaSocket exists but bridge isn’t listening: the error dialog shows `Error: connection_refused: ...`. (`lua/SekonicCalibrator.lua` `_http_request()` and `get_measurement_params()`.)
- Pass criterion:
  - **Pass UAT-02** when the error is **not** `luasocket_unavailable` and remote measurement succeeds once the bridge is running.
- Evidence:
  - Screenshot of the error dialog (if inducing “bridge down” first) OR screenshot/video of successful remote measure dialog. Store under `evidence/<run_id>/screens/`.

#### B. Remote measurement UX (UAT-03 proof)

**B1 — Remote offer gate**
- Run plugin and reach measurement dialog.
- Expected:
  - With `bridge_ip` configured, the measurement dialog offers:
    - `Remote Measurement`, `Enter Manually`, `Cancel`. (`lua/SekonicCalibrator.lua` `get_measurement_params()`.)
- Evidence:
  - Screenshot of the “Measurement … Remote / Manual” dialog.

**B2 — Remote measure → values displayed**
- Click `Remote Measurement`.
- Expected:
  - A confirmation dialog shows received values, formatted with:
    - `CCT`, `Duv`, `CRI`, `R9`, and optionally `TLCI` (only if returned). (`lua/SekonicCalibrator.lua` `get_measurement_params()`.)
- Evidence:
  - Screenshot of “Measurement Received … Values from … meter” dialog.

#### C. End-to-end single-group session (<5 minutes) (UAT-01 proof)

This is the “ship gate” metric: one group end-to-end in < 5 minutes, including remote measure and at least one apply cycle. (See Phase 7 context and roadmap success criteria. `.planning/phases/07-console-uat-hardware-validation/07-CONTEXT.md`, `.planning/ROADMAP.md`.)

**C1 — Use a controlled test showfile**
- Create (or load) a showfile with at least one fixture group that can be safely adjusted.
- [ASSUMED] Because showfile specifics aren’t defined in repo, Phase 7 UAT must document the chosen fixture model(s) and group number(s).

**C2 — Start timer at “Start Calibration”**
- Start timing when selecting `Start Calibration` from the main menu.
- Stop timing when:
  - The group is marked done / accepted and the workflow returns to group selection (or session summary). [ASSUMED]
- Evidence:
  - Record start/stop timestamps and elapsed time in `evidence/<run_id>/timing.csv`.

**C3 — Minimal loop steps (one group)**
- Set session goals (Kelvin target, Duv target, CRI/R9/TLCI goals as appropriate).
- Select group.
- Trigger remote measurement (B2).
- View assessment and apply correction once.
- Re-measure at least once (remote preferred; manual acceptable if bridge fails).
- End the group with either:
  - goals met (pass), or
  - explicit operator acceptance override (allowed, but must be labeled as override per Phase 7 context D-204). (`07-CONTEXT.md`.)
- Evidence:
  - Screen recording (preferred) of the full group flow from the first remote measure through accept/apply and finish.
  - Final screenshot of session summary or group completion state.

#### D. Required error-path proof (auth / bridge down)

At least one controlled failure must be demonstrated to prove operator-facing error UX is safe and actionable.

**D1 — Bridge down / wrong port**
- Stop the bridge (or set `bridge_port` wrong) and attempt Remote Measurement.
- Expected:
  - “Bridge Error” dialog appears with error string (should be `connection_refused...` if LuaSocket works). (`lua/SekonicCalibrator.lua`.)
- Evidence:
  - Screenshot of “Bridge Error” showing the error string and the Retry/Manual/Cancel options.

**D2 — Auth mismatch (only if auth enabled)**
- If the bridge enforces an API key, configure a wrong `bridge_api_key` in plugin config and attempt Remote Measurement.
- Expected:
  - Bridge returns 401; plugin should surface a meaningful error and allow Retry/Manual/Cancel. [ASSUMED] (This repo’s current `lua/SekonicCalibrator.lua` does not show `bridge_api_key` parsing; see Risk R4.)
- Evidence:
  - Screenshot of error dialog with clear “auth” hint (or document mismatch if not present).

### 2) Validating LuaSocket TCP on onPC (UAT-02) with a deterministic indicator

**Deterministic indicator is the literal error token** returned by the Lua code when LuaSocket is absent:

- `_http_request()` calls `pcall(require, "socket")` and returns `nil, "luasocket_unavailable"` on failure. (`lua/SekonicCalibrator.lua`.)
- The remote measurement UI surfaces that token in the “Bridge Error” dialog as `Error: luasocket_unavailable`. (`lua/SekonicCalibrator.lua` `get_measurement_params()`.)

Therefore Phase 7 can validate LuaSocket without ambiguity by inducing a remote measurement attempt and checking:

- **PASS**: error is `connection_refused: ...` when bridge is down, and remote succeeds when bridge is running.
- **FAIL**: error is `luasocket_unavailable` on the target onPC build.

This check is robust even if the bridge is not yet installed; it isolates “LuaSocket present” from “bridge reachable”.

### 3) Evidence artifacts Phase 7 should produce and where to store them in `.planning`

Phase 7 should produce a single evidence bundle per UAT run, with stable naming and minimal required artifacts.

#### Storage location (proposed)

- `.planning/phases/07-console-uat-hardware-validation/evidence/<run_id>/`

Where `<run_id>` is: `YYYYMMDD_<onpc_version>_<mac_model>_<bridge_mode>` (example: `20260702_1.6.1.3_m2pro_real`).

#### Required artifacts (minimal)

- **Terminal outputs**
  - `bridge_status_mock.txt` (A1)
  - `bridge_status_real.txt` (when hardware available)
  - Optional: `bridge_measure_real.txt` (direct `curl -X POST /measure` from macOS host)
- **Timing**
  - `timing.csv` with:
    - `run_id, start_ts, end_ts, elapsed_s, group_id, fixture_make, fixture_model, goals_summary, pass_or_override, notes`
- **Screenshots** (PNG)
  - `screens/measurement_remote_offer.png` (B1)
  - `screens/measurement_received.png` (B2)
  - `screens/bridge_error_luasocket_or_connrefused.png` (A2/D1)
  - `screens/session_summary_or_group_done.png` (C3)
- **Video** (if possible)
  - `video/uat01_single_group_e2e.mp4` covering C3 end-to-end.
- **Bridge log** (if available on the machine running the bridge)
  - `bridge.log` copied from bridge runtime directory. [ASSUMED] (The bridge README states measurements are logged to `bridge.log`; exact location depends on install method.)

#### Artifact “acceptance” rules

- Each requirement (TOP-01, UAT-01/02/03) must have at least one **direct** artifact reference (screenshot/video/log) that a reviewer can validate without interpretation.
- If the 5-minute goal is missed, the timing file must include the cause (“fixture slow to respond”, “USB reconnect”, “operator confusion”, etc.) and whether an explicit override was used (D-204). (`07-CONTEXT.md`.)

### 4) Risk list (requested items) + mitigations

#### R1 — macOS pyusb/libusb issues (permissions, backend stability)
- **What can go wrong**: Python bridge can’t claim USB interface, libusb not found, or device disconnects during measure; real `/measure` fails even though mock works.
- **Impact**: Blocks UAT-01 and UAT-03 on real hardware; could still pass UAT-02 via mock/connection-refused indicator.
- **Mitigation**:
  - Run A1 (mock) first to separate LuaSocket/HTTP issues from USB.
  - Capture `bridge.log` and `curl /status` when failures occur.
- **Tag**: [ASSUMED] (because macOS USB details depend on host; repo doesn’t include macOS-specific troubleshooting beyond the general runbook references).

#### R2 — C-7000 TLCI availability / omission in bridge response
- **What can go wrong**: Bridge response may omit `tlci` (README notes “not in standard response — requires FW > 25 extended mode”). (`sekonic-bridge/README.md`.)
- **Impact**: UAT-03 requires TLCI shown in UI; if bridge doesn’t return it, UI cannot display it.
- **Mitigation**:
  - Phase 7 must record:
    - Whether the returned JSON includes `tlci`
    - Meter firmware version (if visible on device) [ASSUMED]
  - If TLCI missing, update UAT expectation to “TLCI displayed when present; otherwise explicitly shown as missing” (may require Phase 6/8 follow-up if UI doesn’t communicate this clearly).
- **Tag**: [CITED] (TLCI note is explicit in `sekonic-bridge/README.md`.)

#### R3 — Bridge auth key mismatch (plugin vs bridge)
- **What can go wrong**: Bridge requires `X-Bridge-Key` but plugin config doesn’t send it or parses it incorrectly → all routes 401.
- **Impact**: Remote measurement and Bridge Status fail; operator forced into manual entry.
- **Mitigation**:
  - Include controlled D2 test if auth is enabled.
  - Ensure `config.json` handling matches current code.
- **Tag**: [ASSUMED] in this repo state: `lua/SekonicCalibrator.lua` `load_config()` currently documents supported fields as `github_username, bridge_ip, bridge_port` and does not parse `bridge_api_key`. (`lua/SekonicCalibrator.lua`.)

#### R4 — onPC plugin library path differences (macOS vs Windows, GetPath availability)
- **What can go wrong**: Plugin can’t locate `config.json` because `GetPath(Enums.PathType.PluginLibrary)` differs on onPC, or fallback `HostOS()` path differs.
- **Impact**: Bridge is “not configured”, fixture_log read/write fails; UAT blocks early.
- **Mitigation**:
  - Phase 7 must explicitly validate `config.json` load on macOS onPC by observing:
    - main menu button label is `Bridge Status` (configured) vs `Bridge Status (not configured)`. (`lua/SekonicCalibrator.lua` `main()`.)
  - If mis-detected, capture screenshot and add a follow-up fix (Phase 6) without changing Phase 7 scope.
- **Tag**: [VERIFIED] that plugin uses `GetPath(Enums.PathType.PluginLibrary)` with fallback to `~/MALightingTechnology/gma3_library/...` for non-Windows. (`lua/SekonicCalibrator.lua` `get_plugin_dir()`.)

## Notes on repo-state mismatches (important for Phase 7 planning)

- Some planning docs (Phases 4–5) refer to `bridge_api_key` + `X-Bridge-Key` support in plugin config and a split `lua/bridge_client.lua`. In the current working tree, `lua/bridge_client.lua` is absent and `load_config()` does not parse `bridge_api_key`. (`lua/SekonicCalibrator.lua` and `Glob` search results.)
- Phase 7 UAT checklist above is anchored to the code that exists now (monolithic Section 2c). If Phase 6 is expected to land modularized code and auth-aware Bridge Status, Phase 7 must re-verify the exact onPC-visible strings and update this checklist accordingly. [ASSUMED]

---
**Primary sources (codebase-driven):**
- `lua/SekonicCalibrator.lua` (LuaSocket detection token, remote measurement dialogs, Bridge Status UI, config path logic)
- `.planning/phases/05-ma3-http-integration/05-UAT.md` and `05-VERIFICATION.md` (deferred manual tests)
- `.planning/phases/07-console-uat-hardware-validation/07-CONTEXT.md`, `.planning/ROADMAP.md`, `.planning/REQUIREMENTS.md` (Phase 7 gates and topology)
- `README.md`, `sekonic-bridge/README.md` (operator and bridge runbooks; TLCI note)
