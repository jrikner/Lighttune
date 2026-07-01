# Codebase Concerns

**Analysis Date:** 2026-07-01

## Tech Debt

**Monolithic plugin source:**
- Issue: All runtime logic lives in a single 1,431-line file with no module split; color math, JSON DB, UI, patch API, and I/O are interleaved.
- Files: `lua/SekonicCalibrator.lua`
- Impact: Hard to review, test in isolation, or change one layer without touching unrelated code.
- Fix approach: Extract Section 2 (color math) and Section 2b (JSON/DB) into require-able modules once MA3 plugin packaging supports multiple Lua files; keep `main()` as orchestration only.

**Duplicated logic between production and tests:**
- Issue: `test_color_math.lua` inlines ~240 lines copied from `lua/SekonicCalibrator.lua` (Sections 2 and 2b) instead of importing shared code.
- Files: `test_color_math.lua`, `lua/SekonicCalibrator.lua`
- Impact: Color math or DB schema changes can pass tests while production code diverges silently.
- Fix approach: Share a `lua/color_math.lua` (and optionally `lua/fixture_db.lua`) required by both the plugin and the standalone test runner.

**Hand-rolled JSON parser/encoder:**
- Issue: Fixture database uses regex-based `json_get_*`, `%b{}` block extraction, and string concatenation instead of a real JSON library.
- Files: `lua/SekonicCalibrator.lua` (lines 214–289, 229–257), mirrored in `test_color_math.lua`
- Impact: Breaks on escaped quotes in make/model names, nested braces, scientific notation, or malformed hand-edited files; silent record drops when `make`/`model`/`kelvin` fail to parse.
- Fix approach: Use MA3-compatible JSON if available, or tighten schema validation and surface parse errors to the user instead of returning `{}`.

**Dead code — base64 helpers:**
- Issue: `base64_encode` and `base64_decode` are defined but never called anywhere in the plugin.
- Files: `lua/SekonicCalibrator.lua` (lines 165–200)
- Impact: ~35 lines of untested-in-production code; suggests removed community-upload path or unfinished feature.
- Fix approach: Remove if unused, or wire up to the intended upload/encoding workflow and add integration tests.

**Version and manifest drift:**
- Issue: Runtime UI and README advertise v0.4; `plugin.xml` declares `Version="0.1.0"`.
- Files: `plugin.xml`, `lua/SekonicCalibrator.lua` (header and line 1290), `README.md`
- Impact: Console plugin pool shows wrong version; support and release tracking are unreliable.
- Fix approach: Align `plugin.xml` Version with README/code (0.4.0 or semver equivalent).

**README vs implementation drift:**
- Issue: README documents automatic GitHub community upload (`community_upload: true`), `curl`, and `unzip` for GDTF detection; code explicitly states HTTPS upload and `io.popen`/unzip are unavailable and only saves locally.
- Files: `README.md` (features table, requirements, community section), `lua/SekonicCalibrator.lua` (Section 5 comments, `log_fixture_data`)
- Impact: Users configure features that do not exist; wasted setup on console OS tools.
- Fix approach: Update README to match current local-only behavior, or implement the documented upload path if MA3 gains HTTPS.

**Config file path inconsistency:**
- Issue: `load_config()` reads `config.json` from plugin root (`get_plugin_dir()`), but the repo ships `data/config.json.example` and `.gitignore` ignores `data/config.json`.
- Files: `lua/SekonicCalibrator.lua` (`load_config`, lines 1243–1252), `data/config.json.example`, `.gitignore`, `README.md`
- Impact: Users following the example path never get contributor names applied; config appears “broken.”
- Fix approach: Standardize on one path (plugin root or `data/`) and update example, gitignore, and README together.

**Unused `data/measurements/` directory:**
- Issue: Repo reserves `data/measurements/*.json` in `.gitignore` but no code reads or writes there; all logging goes to `data/fixture_log.json`.
- Files: `data/measurements/.gitkeep`, `.gitignore`, `lua/SekonicCalibrator.lua` (`save_fixture_log_local`)
- Impact: Confusing layout for contributors; dead convention.
- Fix approach: Remove the directory or implement per-session/per-group measurement files as originally planned.

**Extensive silent `pcall` swallowing:**
- Issue: Patch API, path resolution, and file save paths wrap failures in `pcall` without logging or user feedback (e.g. `save_fixture_log_local` returns boolean only).
- Files: `lua/SekonicCalibrator.lua` (`get_fixture_from_patch`, `read_capabilities_from_patch`, `save_fixture_log_local`, `get_plugin_dir`)
- Impact: Missing fixture history, failed writes, or wrong capabilities appear as “no data” with no diagnostic.
- Fix approach: Capture errors from `pcall` and show a MessageBox on save/API failures; fail loudly for data loss scenarios.

## Known Bugs

**`get_correction` ignores measured values for SetColor target:**
- Symptoms: Every “Apply” sets the same `target_x`/`target_y` derived only from session target CCT/Duv; measured CCT/Duv affect displayed deltas but not the chromaticity sent to `SetColor`.
- Files: `lua/SekonicCalibrator.lua` (`get_correction`, lines 84–92; apply path lines 1374–1379)
- Trigger: Run calibration, enter any measured values, press Apply repeatedly — console color does not change between attempts.
- Workaround: Manually adjust fixture (Tint, CTB, gel) using hints; plugin does not compute closed-loop setpoint correction from meter readings.

**Historical pre-fill applies the same target as a cold start:**
- Symptoms: “Pre-apply best known correction” uses `get_correction(goals.cct, goals.duv, ref.cct, ref.duv)` but `ref.cct`/`ref.duv` are unused for `target_x`/`target_y`, so pre-fill sets identical xy to a normal apply.
- Files: `lua/SekonicCalibrator.lua` (`apply_historical_prefill`, lines 667–674)
- Trigger: Fixture with prior DB entries; choose “Yes – Pre-apply.”
- Workaround: Treat pre-fill as informational only until correction math incorporates reference measurements.

**CRI/R9 prompts when goals are skipped:**
- Symptoms: `get_measurement_params` always prompts for CRI and R9 even when session goals set those metrics to `GOAL_SKIP`; only TLCI is gated on `track_tlci`.
- Files: `lua/SekonicCalibrator.lua` (`get_measurement_params`, lines 710–724)
- Trigger: Start session with “Skip” for quality metrics.
- Workaround: Enter dummy values or cancel; unnecessary operator steps.

## Security Considerations

**Local JSON files with no integrity checks:**
- Risk: `fixture_log.json` is plain text, world-readable on the console filesystem; tampered or merged files could skew “best” flags or mislead pre-fill/history.
- Files: `lua/SekonicCalibrator.lua` (`json_parse_db_array`, `show_fixture_history`), `data/fixture_log.json` (runtime, gitignored)
- Current mitigation: Append-only schema with recompute of `best_*` flags on write.
- Recommendations: Validate numeric ranges on parse; optionally checksum file header; warn when parse drops records.

**No secrets in repo, but config is local-only:**
- Risk: `config.json` holds GitHub username (not a token); low sensitivity but path confusion may lead users to put tokens in config if README implies upload.
- Files: `data/config.json.example`, `lua/SekonicCalibrator.lua` (`load_config`)
- Current mitigation: `.gitignore` excludes local config and logs.
- Recommendations: Document explicitly that no API tokens are supported in-plugin; never add token fields without secure storage guidance.

**Group name injection into MA3 commands:**
- Risk: `select_group` interpolates user input into `Cmd('Group "'..group..'"')` without escaping; a crafted group name could break command syntax.
- Files: `lua/SekonicCalibrator.lua` (`select_group`, lines 1154–1160)
- Current mitigation: Typical group names are numeric or simple labels.
- Recommendations: Sanitize or reject names containing `"` or command delimiters; prefer numeric group index API when available.

## Performance Bottlenecks

**Full-file read/write on every measurement append:**
- Problem: Each group completion reads entire `fixture_log.json`, parses all records, recomputes flags, sorts, and rewrites the whole file.
- Files: `lua/SekonicCalibrator.lua` (`save_fixture_log_local`, `append_fixture_record`, `recompute_best_flags`, `sort_fixture_records`)
- Cause: Append-only design without incremental index or size cap.
- Improvement path: Cap retained history per fixture/kelvin, or lazy-load history in viewer only; batch writes at session end.

**Patch capability scan loops up to 100 DMX channels:**
- Problem: `read_capabilities_from_patch` iterates `for i = 0, math.max(ch_count - 1, 99)` — always up to 100 channels when count is unknown or zero.
- Files: `lua/SekonicCalibrator.lua` (lines 1120–1143)
- Cause: Defensive default when `dch:Count()` fails inside `pcall`.
- Improvement path: Break early on consecutive nil children; use actual count when available.

**Unbounded append-only database growth:**
- Problem: No pruning or archival; long-running installs accumulate unbounded JSON on console storage.
- Files: `lua/SekonicCalibrator.lua` (`append_fixture_record`), `data/fixture_log.json`
- Cause: By-design append-only community dataset.
- Improvement path: Document export/archive workflow; optional “keep last N per fixture/kelvin” compaction.

## Fragile Areas

**GrandMA3 Patch API surface (undocumented, version-sensitive):**
- Files: `lua/SekonicCalibrator.lua` (`get_fixture_from_patch`, `read_capabilities_from_patch`)
- Why fragile: Relies on `DataPool`, `Groups`, `FixtureType.DMXModes.Default`, `LogicalChannels.Attribute` naming — all may differ across MA3 versions or fixture types.
- Safe modification: Guard each property access with `pcall`; add version detection; test against real patched fixtures on target MA3 build (1.6.1.3 per `plugin.xml`).
- Test coverage: None — pure MA3 integration, not exercised by `test_color_math.lua`.

**HSB fallback after xyY failure:**
- Files: `lua/SekonicCalibrator.lua` (`calibrate_group`, `apply_color_hsb`, `xy_to_rgb`)
- Why fragile: HSB path uses simplified sRGB gamma and max-normalization; fixtures without xyY support get approximate hue/sat only — brightness locked at 1.0.
- Safe modification: Prefer documenting “approx” in UI when HSB used; consider MA3-native color spaces if API exposes them.
- Test coverage: Color conversion unit tests only; no SetColor integration tests.

**Color wheel filter detection heuristic:**
- Files: `lua/SekonicCalibrator.lua` (`read_capabilities_from_patch`, `show_assessment` hints)
- Why fragile: When any `ColorWheel` attribute is found, both `has_color_wheel` and `has_color_wheel_filters` are set true without reading slot names from GDTF XML (explicitly unavailable in MA3 Lua).
- Safe modification: Treat filter hints as conservative; prefer Tint channel hints when `has_tint`.
- Test coverage: None.

**First group member represents entire group:**
- Files: `lua/SekonicCalibrator.lua` (`get_fixture_from_patch`, `read_capabilities_from_patch` — `members:Child(0)`)
- Why fragile: Mixed-fixture groups yield wrong make/model and capability hints for non-representative fixtures.
- Safe modification: Warn when group has multiple fixture types; let user pick representative fixture.
- Test coverage: None.

**MessageBox return-value contract:**
- Files: `lua/SekonicCalibrator.lua` (throughout Section 3)
- Why fragile: All UI flow assumes numeric button indices (1=first button); MA3 API behavior if labels or button order change is untested in CI.
- Safe modification: Centralize button mapping constants; document MA3 MessageBox contract in code comments.
- Test coverage: None.

## Scaling Limits

**Single-threaded synchronous UI workflow:**
- Current capacity: One operator, one group at a time, modal MessageBox chain.
- Limit: No batch calibration of dozens of groups; session length grows linearly with groups × attempts.
- Scaling path: Optional “batch mode” with saved defaults; non-modal progress if MA3 API allows.

**Fixture history viewer loads entire DB into memory:**
- Current capacity: All records loaded for search/display.
- Limit: Very large community merges could slow console UI.
- Scaling path: Paginate search results; index by make/model on load.

## Dependencies at Risk

**GrandMA3 Lua sandbox restrictions:**
- Risk: No `io.popen`, no HTTPS (only documented plain FTP), no runtime `mkdir` — features commonly assumed in generic Lua/plugins are unavailable.
- Impact: Community upload, GDTF file parsing, and shell-based tooling cannot be added without MA platform changes.
- Migration plan: Keep file I/O to plugin-shipped `data/`; use Patch API for GDTF-derived data; document manual export for community sharing (already partially documented in code comments).

**Standalone test runner requires Lua 5.4:**
- Risk: `test_color_math.lua` uses `<<`/`>>` bit operators; README says `lua5.4`; dev/CI environment may lack Lua (not installed in current workspace).
- Impact: Contributors cannot verify 126 tests without local Lua 5.4.
- Migration plan: Add CI job with `lua5.4 test_color_math.lua`; or vendor a test script in docs.

## Missing Critical Features

**Closed-loop chromaticity correction from meter readings:**
- Problem: Core value proposition (“correct fixture to target”) does not adjust setpoints based on measured vs target gap in xy/uv space.
- Blocks: Reliable one-shot calibration; meaningful re-measure loops; historical pre-fill.

**Automated community sync:**
- Problem: Documented opt-in GitHub upload is not implemented; only manual export of `fixture_log.json`.
- Blocks: Shared fixture database growth without user friction.

**Runtime creation of data directory:**
- Problem: Code assumes `data/` exists in plugin package; no `mkdir` fallback.
- Blocks: Installations that omit `data/` fail silently on first save (`save_fixture_log_local` pcall).

## Test Coverage Gaps

**MA3 API integration (Cmd, SetColor, DataPool, MessageBox):**
- What's not tested: Group selection, color application, patch traversal, main menu flow.
- Files: `lua/SekonicCalibrator.lua` (Sections 3b, 4, 6)
- Risk: Regressions only found on physical console.
- Priority: High

**`get_correction` / apply workflow:**
- What's not tested: Whether setpoints change with different measured inputs (would expose current logic gap).
- Files: `lua/SekonicCalibrator.lua` (`get_correction`, `calibrate_group`)
- Risk: Incorrect calibration behavior persists undetected.
- Priority: High

**File I/O and config loading:**
- What's not tested: `save_fixture_log_local`, `load_config`, path fallbacks in `get_plugin_dir`.
- Files: `lua/SekonicCalibrator.lua` (Section 5)
- Risk: Silent data loss on console paths.
- Priority: Medium

**UI goal-skip paths:**
- What's not tested: Session setup with skipped CRI/R9; reference mode; custom metric selection.
- Files: `lua/SekonicCalibrator.lua` (`get_spectral_goals`, `get_measurement_params`)
- Risk: UX bugs like unnecessary prompts.
- Priority: Medium

**Gel hints and capability-aware assessment:**
- What's not tested: `show_assessment` hint branches for caps table combinations.
- Files: `lua/SekonicCalibrator.lua` (`show_assessment`, lines 756–883)
- Risk: Wrong operator guidance for edge fixtures.
- Priority: Low

---

*Concerns audit: 2026-07-01*
