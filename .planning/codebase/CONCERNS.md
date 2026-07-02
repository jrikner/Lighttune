# Codebase Concerns

**Analysis Date:** 2026-07-01

## Branch Divergence (Multi-Branch Analysis)

**Branches compared:** `origin/claude/lighttune-main` (df95d17), `origin/claude/sekonic-remote-api-research-HdMTl` (5cc8bf8), `origin/Lighttune-experimental` (83f74b8, PR #2 merge of Sekonic work).

| Area | `lighttune-main` | Sekonic branches |
|------|------------------|------------------|
| Plugin version | v0.4 (`lua/SekonicCalibrator.lua`) | v0.5 (+657 lines in Lua diff) |
| `sekonic-bridge/` | **Absent** | **+2,448 lines** (13 files) |
| Meter input | Manual `MessageBox` only | Remote bridge + manual fallback + auto-loop |
| Community upload | README still claims opt-in upload; code removed in 0530fd2 | README corrected to local-only export |
| GDTF docs | README matches Patch API implementation | README **regressed** to on-disk GDTF path (see Tech Debt) |

**Merge status:** Sekonic remote API is merged to `origin/Lighttune-experimental` but **not** to `origin/claude/lighttune-main` (default branch). Production baseline lacks bridge server, v0.5 Lua, and `bridge_ip`/`bridge_port` config. Operators on main cannot use remote measurement without merging or cherry-picking.

**Experimental vs research drift:** `Lighttune-experimental` differs from `sekonic-remote-api-research-HdMTl` in five files (`lua/SekonicCalibrator.lua`, `sekonic-bridge/README.md`, `meter_c7000_hid.py`, `meter_mock.py`, `server.py`). Experimental still documents HID/wizard flow; research branch integrated skreader bulk protocol (commit 5cc8bf8). Two “latest Sekonic” snapshots exist — pick one before merge to main.

---

## Tech Debt

**Sekonic work stranded off main:**
- Issue: ~2,400 lines of bridge + v0.5 plugin live only on feature/experimental branches.
- Files: entire `sekonic-bridge/`, `lua/SekonicCalibrator.lua` (Section 2c bridge), `data/config.json.example`
- Impact: Default-branch users see outdated README (community upload, no bridge); Sekonic branch users need non-main checkout to deploy Pi bridge.
- Fix approach: Merge `Lighttune-experimental` or `sekonic-remote-api-research-HdMTl` to `claude/lighttune-main` after reconciling experimental/research diffs; align README and version manifests in same PR.

**HID vs bulk USB naming and dead wizard paths:**
- Issue: Module/class named `C7000HID` and file `meter_c7000_hid.py` implement **USB bulk** (RT1/RM0/ST/NR), not HID. `server.py` still exposes `/learn_trigger`, `_build_trigger_candidates()`, and HID-oriented `/capture` fallback while C-7000 fast path bypasses them. Setup wizard UI still walks discover → capture → learn_trigger even when `/discover` auto-sets `protocol_captured` and `trigger_discovered` for VID `0x0A41`.
- Files: `sekonic-bridge/meter_c7000_hid.py`, `sekonic-bridge/server.py` (`/learn_trigger`, `/capture`, `_build_trigger_candidates`), `lua/SekonicCalibrator.lua` (`run_bridge_setup`, `_run_trigger_discovery`)
- Impact: Operator confusion; `/learn_trigger` probes 1–4 byte HID patterns via `probe_trigger()` that do not match bulk command sequence; wasted 2-minute probes if flags not pre-set; maintenance burden from dual protocol stories.
- Fix approach: Rename module to `meter_c7000_bulk.py`; collapse wizard to discover + test measure for C-7000; retain passive capture only for unknown VID/PID; remove or gate HID probe loop when skreader protocol is active.

**Monolithic plugin source:**
- Issue: All runtime logic lives in a single ~1,431-line file (v0.4 main) / ~1,430+ line file (v0.5 Sekonic); color math, JSON DB, UI, patch API, bridge HTTP, and I/O are interleaved.
- Files: `lua/SekonicCalibrator.lua`
- Impact: Hard to review, test in isolation, or change one layer without touching unrelated code; v0.5 added ~390 lines of bridge networking in same file.
- Fix approach: Extract Section 2 (color math) and Section 2b (JSON/DB) into require-able modules once MA3 plugin packaging supports multiple Lua files; optionally extract Section 2c bridge client.

**Duplicated logic between production and tests:**
- Issue: `test_color_math.lua` inlines ~240 lines copied from `lua/SekonicCalibrator.lua` (Sections 2 and 2b) instead of importing shared code.
- Files: `test_color_math.lua`, `lua/SekonicCalibrator.lua`
- Impact: Color math or DB schema changes can pass tests while production code diverges silently.
- Fix approach: Share a `lua/color_math.lua` (and optionally `lua/fixture_db.lua`) required by both the plugin and the standalone test runner.

**Hand-rolled JSON parser/encoder:**
- Issue: Fixture database uses regex-based `json_get_*`, `%b{}` block extraction, and string concatenation instead of a real JSON library. Bridge responses parsed with `body:match('"cct"%s*:%s*(%-?[%d%.]+)')` etc.
- Files: `lua/SekonicCalibrator.lua` (lines ~214–289, 229–257, `bridge_fetch_measurement`), mirrored in `test_color_math.lua`
- Impact: Breaks on escaped quotes in make/model names, nested braces, scientific notation, or malformed hand-edited files; bridge JSON with reordered keys or nested objects may parse incorrectly.
- Fix approach: Use MA3-compatible JSON if available; tighten schema validation; surface parse errors to the user instead of returning `{}` or `malformed_response`.

**Dead code — base64 helpers:**
- Issue: `base64_encode` and `base64_decode` are defined but never called. Leftover from removed GitHub upload path (pre-0530fd2 `upload_community_file` used curl + base64 content encoding).
- Files: `lua/SekonicCalibrator.lua` (lines ~165–200)
- Impact: ~35 lines of untested-in-production code; misleading signal that upload may return.
- Fix approach: Remove dead helpers or document why they remain.

**Community upload removed but still documented on main:**
- Issue: Commit 0530fd2 removed `curl_exec()`, `upload_community_file()`, `github_token`, and `community_upload` from Lua (GrandMA3 has no `io.popen`/HTTPS). **`origin/claude/lighttune-main` README still lists** “Community database” with `"community_upload": true`, plus `curl`/`unzip` requirements. Sekonic branch README fixes this; Lua header on Sekonic branch still mentions “community upload” in historical comment on line 9 until cleaned.
- Files: `README.md` (main), `lua/SekonicCalibrator.lua` (Section 5 comments both branches), `data/config.json.example`
- Impact: Users configure features that do not exist; may store tokens in config expecting upload (removed token field without README update on main).
- Fix approach: Merge Sekonic README doc fixes to main; remove stale header comment; never re-add curl without confirmed MA3 API support.

**README vs implementation drift (branch-dependent):**
- Issue (main): README documents automatic GitHub community upload and `unzip` for GDTF; code uses Patch API only and local save.
- Issue (Sekonic branch): README **GDTF section reverted** to reading files from `~/MALightingTechnology/gma3_library/gdtf/`; code still uses **Patch API only** (`read_capabilities_from_patch`, Section 3b comments).
- Files: `README.md`, `lua/SekonicCalibrator.lua` (Section 3b)
- Impact: Users search for GDTF files on disk; capability detection still depends on patch/group membership.
- Fix approach: Restore Patch-API-first README on Sekonic branch (as on main post-0530fd2); single source of truth before merge.

**Bridge README says `socket.http`; code uses raw TCP:**
- Issue: `sekonic-bridge/README.md` diagram states plugin “calls /measure via socket.http”; `SekonicCalibrator.lua` Section 2c uses `require("socket").tcp()` and manual HTTP/1.0 framing (GrandMA3 has no HTTPS; `socket.http` availability is unverified).
- Files: `sekonic-bridge/README.md`, `lua/SekonicCalibrator.lua` (`_http_request`)
- Impact: Integrators test wrong API; debugging network issues assumes wrong client stack.
- Fix approach: Document LuaSocket raw TCP; add runtime probe for `socket.http` vs `socket.tcp` if both exist on target MA3 build.

**Version and manifest drift:**
- Issue: Runtime UI advertises v0.4 (main) or v0.5 (Sekonic); `plugin.xml` declares `Version="0.1.0"` on all branches.
- Files: `plugin.xml`, `lua/SekonicCalibrator.lua`, `README.md`
- Impact: Console plugin pool shows wrong version; support and release tracking are unreliable.
- Fix approach: Align `plugin.xml` Version with README/code (0.5.0 on Sekonic merge).

**Config file path inconsistency:**
- Issue: `load_config()` reads `config.json` from plugin root (`get_plugin_dir()/config.json`), but repo ships `data/config.json.example` and `.gitignore` ignores `data/config.json`. Sekonic example adds `bridge_ip`/`bridge_port` under `data/` path in docs.
- Files: `lua/SekonicCalibrator.lua` (`load_config`), `data/config.json.example`, `.gitignore`, `README.md`
- Impact: Users following the example path never get bridge IP or contributor name applied; remote measurement appears “not configured.”
- Fix approach: Standardize on one path (plugin root or `data/`) and update example, gitignore, and README together.

**Unused `data/measurements/` directory:**
- Issue: Repo reserves `data/measurements/*.json` in `.gitignore` but no code reads or writes there; all logging goes to `data/fixture_log.json`.
- Files: `data/measurements/.gitkeep`, `.gitignore`, `lua/SekonicCalibrator.lua` (`save_fixture_log_local`)
- Impact: Confusing layout for contributors; dead convention.
- Fix approach: Remove the directory or implement per-session/per-group measurement files as originally planned.

**Extensive silent `pcall` swallowing:**
- Issue: Patch API, path resolution, file save, and USB/kernel-driver paths wrap failures without logging or user feedback.
- Files: `lua/SekonicCalibrator.lua`; `sekonic-bridge/meter_c7000_hid.py` (`detach_kernel_driver` except pass)
- Impact: Missing fixture history, failed writes, wrong capabilities, or failed USB attach appear as “no data” / `meter_not_found` with no diagnostic.
- Fix approach: Capture errors from `pcall` and show MessageBox on save/API failures; log USB detach failures on bridge.

**Legacy setup artifacts on Pi:**
- Issue: `setup-pi.sh` udev rules use broad `SUBSYSTEM=="usb"` fallback with TODO placeholders; comments still say “HID access.”
- Files: `sekonic-bridge/setup-pi.sh` (lines ~65–81)
- Impact: Over-permissive USB access on show Pi; wrong mental model (HID vs bulk).
- Fix approach: Ship confirmed VID/PID `0x0A41`/`0x7003` rules from skreader; remove broad fallback after discover.

---

## Known Bugs

**`get_correction` ignores measured values for SetColor target:**
- Symptoms: Every “Apply” sets the same `target_x`/`target_y` derived only from session target CCT/Duv; measured CCT/Duv affect displayed deltas but not the chromaticity sent to `SetColor`.
- Files: `lua/SekonicCalibrator.lua` (`get_correction`, apply path)
- Trigger: Run calibration, enter any measured values, press Apply repeatedly — console color does not change between attempts.
- Workaround: Manually adjust fixture (Tint, CTB, gel) using hints; plugin does not compute closed-loop setpoint correction from meter readings. **Auto-loop on Sekonic branch re-measures but still applies same xy target.**

**Historical pre-fill applies the same target as a cold start:**
- Symptoms: “Pre-apply best known correction” uses reference CCT/Duv in display only; `target_x`/`target_y` unchanged.
- Files: `lua/SekonicCalibrator.lua` (`apply_historical_prefill`)
- Trigger: Fixture with prior DB entries; choose “Yes – Pre-apply.”
- Workaround: Treat pre-fill as informational only.

**CRI/R9 prompts when goals are skipped:**
- Symptoms: `get_measurement_params` always prompts for CRI and R9 even when session goals set those metrics to `GOAL_SKIP`; only TLCI is gated on `track_tlci`.
- Files: `lua/SekonicCalibrator.lua` (`get_measurement_params`)
- Trigger: Start session with “Skip” for quality metrics; also affects manual fallback after bridge error.
- Workaround: Enter dummy values or cancel.

**TLCI missing from real C-7000 but expected in UI/mock:**
- Symptoms: `meter_c7000_hid.py` `_parse()` returns cct/duv/cri/r9 only (TLCI requires FW>25 extended mode). `meter_mock.py` always returns TLCI. Bridge README and plugin dialogs show TLCI lines when present; goals_met checks TLCI when goal set — real bridge may omit field while mock includes it.
- Files: `sekonic-bridge/meter_c7000_hid.py`, `sekonic-bridge/meter_mock.py`, `lua/SekonicCalibrator.lua` (`bridge_fetch_measurement`, `goals_met`, auto-loop UI)
- Trigger: C-7000 on hardware with TLCI goal enabled; remote measurement succeeds but TLCI nil — goal check may pass incorrectly or UI inconsistent vs mock testing.
- Workaround: Treat TLCI as optional in bridge responses; document FW requirement; align mock to omit TLCI when simulating production meter.

**No USB hot-plug recovery on bridge:**
- Symptoms: If C-7000 disconnects after server start, `_meter` stays disconnected until process restart; `/measure` returns 503.
- Files: `sekonic-bridge/server.py` (`_load_meter`, lifespan, `/measure`)
- Trigger: USB cable bump during show.
- Workaround: `systemctl restart sekonic-bridge`; call `/discover` does not reconnect existing `_meter` instance.

---

## Security Considerations

**Unauthenticated HTTP bridge on show network (no TLS):**
- Risk: `server.py` binds `0.0.0.0:8765` by default; no API key, token, or TLS. Any host on the lighting network can `GET /status`, `POST /measure`, `POST /learn_trigger`, `POST /capture`, `GET /discover` — triggering real measurements or probing USB.
- Files: `sekonic-bridge/server.py` (`main()`, all routes), `sekonic-bridge/sekonic-bridge.service`, `data/config.json.example` (`bridge_ip`/`bridge_port`)
- Current mitigation: Show-network isolation assumed; Pi dedicated role; systemd runs as `sekonic` user (not root).
- Recommendations: Bind to stage VLAN IP only; add shared-secret header or mTLS; firewall port 8765 to MA3 console IP; document that GrandMA3 Lua cannot do HTTPS so bridge must stay HTTP — protect at network layer.

**GrandMA3 Lua: no HTTPS for plugin-side calls:**
- Risk: Plugin uses cleartext HTTP/1.0 to bridge; credentials cannot be sent safely from console; MITM on show WiFi could alter measurement JSON (CCT/CRI spoofing).
- Files: `lua/SekonicCalibrator.lua` (Section 2c `_http_request`)
- Current mitigation: Isolated show network; operator confirms measurements in MessageBox before accept.
- Recommendations: Segment bridge traffic; optional HMAC in JSON body verified by bridge (requires shared secret in `config.json` — document not to commit).

**Local JSON files with no integrity checks:**
- Risk: `fixture_log.json` is plain text, world-readable on the console filesystem; tampered files could skew “best” flags or mislead pre-fill/history.
- Files: `lua/SekonicCalibrator.lua` (`json_parse_db_array`, `show_fixture_history`), `data/fixture_log.json` (runtime, gitignored)
- Current mitigation: Append-only schema with recompute of `best_*` flags on write.
- Recommendations: Validate numeric ranges on parse; warn when parse drops records.

**Config path confusion and removed token fields:**
- Risk: Pre-0530fd2 builds accepted `github_token` in config; current code ignores it but main README may lead users to expect upload. `bridge_ip` in wrong path (`data/config.json` vs plugin root) exposes no secret but breaks security assumptions (operators paste secrets into wrong file).
- Files: `data/config.json.example`, `lua/SekonicCalibrator.lua` (`load_config`), `README.md` (main)
- Recommendations: Document explicitly that no API tokens are supported in-plugin; single config path.

**Group name injection into MA3 commands:**
- Risk: `select_group` interpolates user input into `Cmd('Group "'..group..'"')` without escaping.
- Files: `lua/SekonicCalibrator.lua` (`select_group`)
- Current mitigation: Typical group names are numeric or simple labels.
- Recommendations: Sanitize or reject names containing `"` or command delimiters.

**Broad USB udev fallback on Pi:**
- Risk: `setup-pi.sh` grants `sekonic` group access to all USB devices until VID/PID confirmed.
- Files: `sekonic-bridge/setup-pi.sh`
- Recommendations: Tighten rules after first `discover_device.py` run.

---

## Performance Bottlenecks

**Blocking measurement holds bridge lock up to 35s:**
- Problem: `/measure` runs synchronous USB I/O in executor with 35s timeout; concurrent requests get 409.
- Files: `sekonic-bridge/server.py` (`/measure`, `_measurement_lock`)
- Cause: Real spectrometer cycle ~1.5–20s + poll interval.
- Improvement path: Acceptable for single operator; document one client at a time.

**Full-file read/write on every measurement append:**
- Problem: Each group completion reads entire `fixture_log.json`, parses all records, recomputes flags, sorts, and rewrites the whole file.
- Files: `lua/SekonicCalibrator.lua` (`save_fixture_log_local`, `append_fixture_record`)
- Improvement path: Cap retained history per fixture/kelvin, or batch writes at session end.

**Patch capability scan loops up to 100 DMX channels:**
- Problem: `read_capabilities_from_patch` iterates `for i = 0, math.max(ch_count - 1, 99)`.
- Files: `lua/SekonicCalibrator.lua` (Section 3b)
- Improvement path: Break early on consecutive nil children; use actual count when available.

**Auto-loop adds up to 3 bridge round-trips per group:**
- Problem: Sekonic v0.5 `MAX_AUTO_ATTEMPTS = 3` with 38s HTTP timeout each — worst case ~2 minutes blocking UI per group.
- Files: `lua/SekonicCalibrator.lua` (inner loop ~1840–1920)
- Improvement path: Configurable attempt cap; skip confirmation dialog on auto-loop when goals_met.

---

## Fragile Areas

**USB/HID protocol and device discovery:**
- Files: `sekonic-bridge/meter_c7000_hid.py`, `sekonic-bridge/discover_device.py`, `sekonic-bridge/server.py` (`/discover`)
- Why fragile: Depends on pyusb, libusb, kernel driver detach, fixed endpoints `0x02`/`0x81`, VID/PID defaults `0x0A41`/`0x7003` (skreader; other generations may differ); passive capture fallback tries struct guesses on unknown meters; duplicate discovery logic in CLI script vs HTTP endpoint.
- Safe modification: Run `discover_device.py` on target Pi before deploy; persist `device_config.json`; test with physical C-7000 on Pi OS version used in `build-image.sh`.
- Test coverage: None automated; `--mock` only.

**GrandMA3 Lua networking (Section 2c):**
- Files: `lua/SekonicCalibrator.lua` (`_http_request`, `bridge_fetch_measurement`, `run_bridge_setup`)
- Why fragile: Assumes `require("socket")` works on target MA3 build; HTTP/1.0 regex parsing; no retry backoff; 38s blocking receive on console UI thread.
- Safe modification: Test on MA3 v1.6.1.3 (`plugin.xml` DataVersion); verify LuaSocket availability matches `lua.ftp` documentation.
- Test coverage: None — not in `test_color_math.lua`.

**GrandMA3 Patch API surface (undocumented, version-sensitive):**
- Files: `lua/SekonicCalibrator.lua` (`get_fixture_from_patch`, `read_capabilities_from_patch`)
- Why fragile: Relies on `DataPool`, `Groups`, `FixtureType.DMXModes.Default`, `LogicalChannels.Attribute` naming.
- Safe modification: Guard each property access with `pcall`; test against real patched fixtures on target MA3 build.
- Test coverage: None.

**Mock vs real meter convergence:**
- Files: `sekonic-bridge/meter_mock.py`, `sekonic-bridge/meter_c7000_hid.py`, `sekonic-bridge/server.py` (`--mock`, status flag overrides)
- Why fragile: Mock returns TLCI and improving progression; real driver does not; mock sets all wizard flags true in `/status`; developers may validate auto-loop against mock then fail on hardware TLCI/goals.
- Safe modification: Add `--mock-realistic` mode without TLCI; integration test script comparing JSON schema from both backends.
- Test coverage: None.

**Manual entry fallback paths:**
- Files: `lua/SekonicCalibrator.lua` (`get_measurement_params`, inner loop `user_manual` flag)
- Why fragile: Multiple `goto bridge_retry` paths; switching to manual mid auto-loop sets `user_manual` permanently for group; bridge errors offer Retry/Manual/Cancel with attempt counter manipulation (`attempt = attempt - 1` on retry).
- Safe modification: Centralize fallback state machine; add tests for button index assumptions.
- Test coverage: None.

**HSB fallback after xyY failure:**
- Files: `lua/SekonicCalibrator.lua` (`calibrate_group`, `apply_color_hsb`)
- Why fragile: HSB path uses simplified sRGB gamma; fixtures without xyY support get approximate hue/sat only.
- Test coverage: Color conversion unit tests only.

**Color wheel filter detection heuristic:**
- Files: `lua/SekonicCalibrator.lua` (`read_capabilities_from_patch`, `show_assessment`)
- Why fragile: `has_color_wheel_filters` set true whenever any ColorWheel attribute found.
- Test coverage: None.

**First group member represents entire group:**
- Files: `lua/SekonicCalibrator.lua` (`get_fixture_from_patch`, `read_capabilities_from_patch`)
- Why fragile: Mixed-fixture groups yield wrong make/model and capability hints.
- Test coverage: None.

**MessageBox return-value contract:**
- Files: `lua/SekonicCalibrator.lua` (throughout Section 3 and bridge UI)
- Why fragile: All UI flow assumes numeric button indices (1=first button).
- Test coverage: None.

---

## Scaling Limits

**Single-threaded synchronous UI workflow:**
- Current capacity: One operator, one group at a time, modal MessageBox chain; bridge adds network latency per measurement.
- Limit: No batch calibration of dozens of groups; session length grows linearly with groups × attempts.
- Scaling path: Optional “batch mode” with saved defaults.

**Single bridge meter instance:**
- Current capacity: One C-7000 per Pi; one `/measure` at a time.
- Limit: Multiple fixtures on stage need multiple Pis or manual meter carry.
- Scaling path: Document one Pi per measurement station.

**Fixture history viewer loads entire DB into memory:**
- Current capacity: All records loaded for search/display.
- Limit: Very large merged logs could slow console UI.
- Scaling path: Paginate search results.

---

## Dependencies at Risk

**GrandMA3 Lua sandbox restrictions:**
- Risk: No `io.popen`, no HTTPS (only documented plain FTP), no runtime `mkdir` — community upload and GDTF file parsing removed accordingly; bridge adds only raw TCP HTTP client.
- Impact: Cannot call bridge over TLS from plugin; cannot restore curl-based upload without platform change.
- Migration plan: Keep Pi bridge for hardware access; network isolate HTTP; manual export for community sharing.

**pyusb / libusb on Raspberry Pi:**
- Risk: OS upgrades, kernel driver changes, or different Sekonic USB IDs break connection; udev misconfiguration blocks access.
- Files: `sekonic-bridge/requirements.txt`, `setup-pi.sh`, `meter_c7000_hid.py`
- Migration plan: Pin Pi OS image version in `build-image.sh`; document `discover_device.py` and `lsusb` troubleshooting in bridge README.

**Standalone test runner requires Lua 5.4:**
- Risk: `test_color_math.lua` uses bit operators; bridge and plugin paths untested in CI.
- Impact: 126 color-math tests run locally only; zero coverage for Sekonic integration.
- Migration plan: Add CI with `lua5.4 test_color_math.lua`; optional httpx tests against `server.py --mock`.

**skreader / Sekonic protocol provenance:**
- Risk: Protocol derived from third-party MIT project (kinglevel/skreader), not official Sekonic SDK; FW updates could change offsets or TLCI availability.
- Files: `sekonic-bridge/meter_c7000_hid.py` (header comment, `_OFF_*` constants)
- Migration plan: Capture golden NR response samples per firmware; version gate in `device_config.json`.

---

## Missing Critical Features

**Closed-loop chromaticity correction from meter readings:**
- Problem: Core value proposition (“correct fixture to target”) does not adjust setpoints based on measured vs target gap in xy/uv space. Remote auto-loop only automates **reading** the meter, not **computing** correction.
- Blocks: Reliable one-shot calibration; meaningful re-measure loops; historical pre-fill.

**Sekonic remote measurement on main branch:**
- Problem: Production default branch has no bridge server or v0.5 plugin integration.
- Blocks: FOH remote workflow described in Sekonic README.

**Automated community sync:**
- Problem: Was implemented via curl in 204ca9c, removed in 0530fd2 for MA3 compliance; never replaced. Sekonic branch README no longer promises it; main README still does.
- Blocks: Shared fixture database growth without manual PR/export.

**Runtime creation of data directory:**
- Problem: Code assumes `data/` exists in plugin package; no `mkdir` fallback.
- Blocks: Installations that omit `data/` fail silently on first save.

**Bridge authentication and TLS termination:**
- Problem: No auth/TLS on Pi service; MA3 cannot do HTTPS client.
- Blocks: Safe bridge exposure on shared venue networks without VLAN/firewall discipline.

---

## Test Coverage Gaps

**Sekonic bridge (all branches with `sekonic-bridge/`):**
- What's not tested: USB connect/measure, `/discover`, `/capture`, `/learn_trigger`, `/measure`, mock vs real schema parity, concurrent measure rejection.
- Files: `sekonic-bridge/server.py`, `meter_c7000_hid.py`, `meter_mock.py`
- Risk: Protocol regressions only found on Pi with hardware.
- Priority: High (before merge to main)

**MA3 bridge client (Section 2c):**
- What's not tested: `_http_request`, `bridge_fetch_measurement`, setup wizard flow, auto-loop, manual fallback transitions.
- Files: `lua/SekonicCalibrator.lua`
- Risk: LuaSocket unavailable or behavior change on console undetected until show.
- Priority: High

**MA3 API integration (Cmd, SetColor, DataPool, MessageBox):**
- What's not tested: Group selection, color application, patch traversal, main menu flow.
- Files: `lua/SekonicCalibrator.lua` (Sections 3b, 4, 6)
- Risk: Regressions only found on physical console.
- Priority: High

**`get_correction` / apply workflow:**
- What's not tested: Whether setpoints change with different measured inputs.
- Files: `lua/SekonicCalibrator.lua`
- Risk: Incorrect calibration behavior persists undetected.
- Priority: High

**File I/O and config loading (including bridge_ip):**
- What's not tested: `save_fixture_log_local`, `load_config`, path fallbacks, wrong example path for config.
- Files: `lua/SekonicCalibrator.lua` (Section 5)
- Risk: Silent data loss; bridge never configured.
- Priority: Medium

**UI goal-skip paths and TLCI-from-bridge:**
- What's not tested: Session setup with skipped CRI/R9; TLCI goal with real bridge response lacking TLCI field.
- Files: `lua/SekonicCalibrator.lua`
- Risk: UX bugs and false goal pass/fail.
- Priority: Medium

---

*Concerns audit: 2026-07-01*
