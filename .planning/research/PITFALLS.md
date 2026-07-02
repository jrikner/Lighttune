# Domain Pitfalls

**Domain:** GrandMA3 Lua plugin + Raspberry Pi HTTP bridge + Sekonic C-7000 USB spectrometer calibration  
**Project:** Lighttune (SekonicCalibrator)  
**Researched:** 2026-07-01  
**Sources:** `.planning/PROJECT.md`, `.planning/codebase/CONCERNS.md`, `.planning/codebase/TESTING.md`, prior experimental branches, MA Lighting Forum (LuaSocket blocking), skreader protocol provenance

---

## Phase Mapping Key

Roadmap phases below are **recommended** for this milestone (no `ROADMAP.md` yet). Adjust numbering when the roadmap is finalized.

| Phase | Focus |
|-------|--------|
| **P1** | Canonical merge & branch reconciliation |
| **P2** | Clean architecture (module boundaries) |
| **P3** | Shared test strategy & CI |
| **P4** | Pi bridge production (USB, deploy, mock realism) |
| **P5** | MA3 plugin ↔ HTTP integration |
| **P6** | Operator UX, docs/manifest alignment, show readiness |
| **P7** | Console UAT & validation on real MA3 + hardware |

---

## Critical Pitfalls

Mistakes that cause rewrites, show-stopping failures, or silent wrong calibration.

### Pitfall 1: Treating experimental branches as a single source of truth

**What goes wrong:** Two “latest Sekonic” snapshots exist (`Lighttune-experimental` vs `sekonic-remote-api-research-HdMTl`). Merging the wrong one—or cherry-picking without reconciliation—reintroduces HID wizard paths, stale README (GDTF on-disk, community upload), or divergent bulk drivers.

**Why it happens:** PR #2 merged research into experimental with five file deltas; main never received any Sekonic work; developers pick whichever branch they cloned last.

**Consequences:** Production baseline lacks bridge; integrators follow contradictory docs; merge conflicts hide regressions (README regressed on Sekonic branch while code uses Patch API only).

**Prevention:** Pick one canonical Sekonic snapshot (research bulk protocol + experimental integration fixes); single reconciliation PR to main with README, `plugin.xml`, and version aligned in the same change.

**Detection:** `sekonic-bridge/` absent on default branch; `plugin.xml` Version ≠ runtime header; README mentions features removed in Lua.

**Address in phase:** **P1** (primary), **P6** (doc/manifest lockstep)

---

### Pitfall 2: Monolithic plugin file — change one layer, break another

**What goes wrong:** Color math, JSON DB, Patch API, bridge HTTP, and calibration UI live in one ~1.4k–2k line file. v0.5 added ~390 lines of networking into the same file. Reviews miss cross-cutting edits; bridge regex parsers sit beside Kang et al. CCT math.

**Why it happens:** MA3 historically shipped single-file plugins; early v0.4 never split modules; v0.5 bolted Section 2c onto Section 2.

**Consequences:** Cannot test bridge client without loading MA3 globals; risky refactors; repeated copy-paste into `test_color_math.lua`.

**Prevention:** Extract `color_math.lua`, `fixture_db.lua`, `bridge_client.lua` as require-able components once packaging supports multiple Lua files; keep `SekonicCalibrator.lua` as thin orchestration.

**Detection:** Any edit to Section 2 requires manual mirror in tests; grep shows bridge regex beside `cct_to_xy`.

**Address in phase:** **P2** (primary), **P3** (enables real imports in tests)

---

### Pitfall 3: Hand-rolled JSON — silent parse failures and false “success”

**What goes wrong:** Fixture DB and bridge responses parsed with regex (`%b{}`, `body:match('"cct"%s*:%s*...')`). Escaped quotes in make/model, reordered JSON keys, scientific notation, or nested objects break parsing. Failures return `{}` or `malformed_response` without operator-visible detail.

**Why it happens:** No MA3 JSON library assumed; v0.4 pattern extended to bridge without schema validation.

**Consequences:** History pre-fill empty; remote measurement shows zeros; goals_met passes/fails on wrong fields; tests pass on duplicated inline copy while production diverges.

**Prevention:** Shared encoder/parser module with explicit error surfaces; validate numeric ranges; MessageBox on parse failure; golden JSON fixtures in tests.

**Detection:** Fixture names with `"` in patch; bridge returns TLCI only on extended FW; manual edit of `fixture_log.json`.

**Address in phase:** **P2** (extract + harden), **P3** (golden fixtures), **P5** (bridge response schema)

---

### Pitfall 4: Closed-loop calibration assumed but not implemented

**What goes wrong:** `get_correction` and `apply_historical_prefill` derive `target_x`/`target_y` only from session target CCT/Duv, not measured gap. Auto-loop re-measures via bridge but applies the same xy setpoint each attempt.

**Why it happens:** Core workflow built around operator manual adjustment (Tint, gel hints); remote measure automated reading only.

**Consequences:** Operators believe plugin “corrects” fixtures; repeated Apply/remote measure does not move console color; broadcast accuracy goal blocked despite green UI.

**Prevention:** Document honestly until correction math ships; or implement measured→target delta in xy/uv before marketing auto-loop as calibration.

**Detection:** Apply with different measured CCT/Duv — SetColor arguments unchanged.

**Address in phase:** **P2** (domain clarity), **P6** (UX copy), **P7** (UAT acceptance criteria)

---

### Pitfall 5: HID naming vs USB bulk protocol — wrong setup path on show

**What goes wrong:** `meter_c7000_hid.py` / `C7000HID` implement **USB bulk** (RT1/RM0/ST/NR), not HID reports. Server still exposes `/learn_trigger`, HID-oriented `/capture`, and setup wizard steps (discover → capture → learn_trigger) even when `/discover` auto-sets flags for VID `0x0A41`. `/learn_trigger` probes 1–4 byte HID patterns unrelated to bulk sequence.

**Why it happens:** Early prototype assumed HID; skreader bulk integrated later without renaming or collapsing wizard.

**Consequences:** Operators run 2-minute useless trigger probes; docs say “HID access”; udev rules use broad `SUBSYSTEM=="usb"` fallback; integrators debug wrong protocol layer.

**Prevention:** Rename to `meter_c7000_bulk.py`; wizard = discover + test measure for known VID/PID; gate HID paths to unknown devices only; tighten udev to `0x0A41`/`0x7003`.

**Detection:** `learn_trigger` in logs during C-7000 setup; filename contains `hid` but code uses `bulk` endpoints `0x02`/`0x81`.

**Address in phase:** **P1** (pick bulk-first branch), **P4** (primary), **P6** (README/setup-pi.sh)

---

### Pitfall 6: MA3 Lua networking — UI freeze and wrong client assumptions

**What goes wrong:** GMA3 plugins run as **coroutines on the UI thread**, not background threads (unlike GMA2). LuaSocket `connect`/`receive` **block the entire console UI** until timeout. Experimental code uses 38s receive timeout on `/measure` (real spectrometer cycle 1.5–20s+). Docs claim `socket.http`; code uses raw TCP HTTP/1.0. `require("socket")` availability varies by MA3 build — untested on target `DataVersion="1.6.1.3"`.

**Why it happens:** Assumption that network I/O is async; README written for ideal LuaSocket HTTP module; no on-console probe.

**Consequences:** FOH console frozen up to 38s per measurement; auto-loop ×3 ≈ 2 minutes blocked UI; show stop if operator triggers measure during cueing; integrators test wrong API stack.

**Prevention:** Document blocking behavior; use `'t'` total timeout mode where applicable; `coroutine.yield()` between poll chunks if splitting reads; cap auto-loop attempts; runtime probe `socket.tcp` vs `socket.http`; test on physical MA3 before merge.

**Detection:** UI unresponsive during Bridge Status or remote measure; System Monitor shows plugin not yielding.

**Address in phase:** **P5** (primary), **P7** (on-console validation)

**MA3 networking limits (summary):**

| Constraint | Implication |
|------------|-------------|
| No `io.popen` / `os.execute` | No curl, no shell-out to Pi |
| No HTTPS client | Cleartext HTTP only; TLS must terminate off-console |
| LuaSocket blocking | Long `/measure` waits freeze UI |
| Single coroutine model | No true background bridge listener on console |
| `lua.ftp` documents TCP | Raw HTTP/1.0 over `socket.tcp()` is the validated pattern |
| No runtime `mkdir` | Plugin package must ship `data/` or saves fail silently |

---

### Pitfall 7: HTTP bridge on show LAN — trust model and spoofing

**What goes wrong:** Bridge binds `0.0.0.0:8765`, no auth, no TLS. Any host on the lighting network can `POST /measure`, probe USB, or read `/status`. Plugin sends cleartext JSON; MITM on shared venue WiFi could spoof CCT/CRI. MA3 **cannot** send shared secrets over HTTPS.

**Why it happens:** Pragmatic v1 topology (Pi sidecar); MA3 platform constraint forces HTTP from plugin.

**Consequences:** Rogue measurement triggers during rehearsal; falsified readings accepted if operator does not confirm; compliance issues on shared networks.

**Prevention:** VLAN/firewall port 8765 to console IP only; bind Pi to stage subnet IP; optional HMAC in JSON verified by bridge (secret in local `config.json`, never committed); operator MessageBox confirmation before accepting remote values; document “trusted show LAN only.”

**Detection:** `nmap` shows 8765 open to entire subnet; bridge README omits network segmentation.

**Address in phase:** **P4** (bind/firewall/systemd), **P5** (client timeouts/confirm UX), **P6** (operator runbook)

---

### Pitfall 8: USB protocol fragility — hardware, OS, and firmware drift

**What goes wrong:** Protocol derived from third-party skreader (not official Sekonic SDK). Fixed endpoints, 2380-byte NR payload, FW-dependent TLCI offsets. pyusb requires kernel driver detach; Pi OS upgrade can break libusb. No hot-plug recovery — USB bump leaves `_meter` stale until `systemctl restart`. C-700 vs C-7000 vs future PID confusion.

**Why it happens:** No official SDK; reverse-engineered bulk sequence; single long-lived meter instance in server lifespan.

**Consequences:** 503 `meter_not_connected` mid-show; TLCI goal enabled but field absent on FW ≤25; discover works once then measure fails after cable wiggle.

**Prevention:** Pin Pi OS in `build-image.sh`; golden NR byte fixtures per firmware in tests; reconnect path on `/measure` failure; `device_config.json` version gate; `--mock-realistic` without TLCI for dev parity.

**Detection:** TLCI in mock but not hardware; `/discover` OK then `/measure` 503 after replug.

**Address in phase:** **P4** (primary), **P3** (golden files), **P7** (hardware UAT)

---

## Moderate Pitfalls

### Pitfall 9: Duplicated test logic — production and tests diverge silently

**What goes wrong:** `test_color_math.lua` inlines ~240 lines copied from Sections 2 and 2b instead of `require` shared modules. Section 2c (bridge) not mirrored at all. Editing production without mirroring tests → 126 passing tests, wrong runtime.

**Why it happens:** Plugin ends with `return main` and MA3 globals — early choice to duplicate rather than extract.

**Consequences:** JSON schema or color math regression ships green CI.

**Prevention:** Shared `lua/color_math.lua` + `lua/fixture_db.lua`; CI runs `lua5.4 test_color_math.lua`; add host-testable pure functions from bridge client (`goals_met`, response normalizers).

**Address in phase:** **P3** (primary), **P2** (prerequisite)

---

### Pitfall 10: Mock vs real meter convergence — false confidence from `--mock`

**What goes wrong:** `MockMeter` always returns TLCI, improves over 5 calls, sets all wizard flags true. Real `meter_c7000_hid` omits TLCI on many FW builds; passive capture paths differ. Developers validate auto-loop on mock; fail on hardware TLCI goals.

**Why it happens:** Mock optimized for happy-path demo; no `--mock-realistic` mode; no schema parity tests.

**Consequences:** goals_met false positive/negative; setup wizard appears complete on mock only.

**Prevention:** `test_meter_mock.py` + `test_server_mock.py`; optional mock without TLCI; integration checklist comparing JSON keys from both backends.

**Address in phase:** **P3**, **P4**

---

### Pitfall 11: Config and doc path drift — bridge “not configured”

**What goes wrong:** `load_config()` reads `get_plugin_dir()/config.json`; repo ships `data/config.json.example`; `.gitignore` ignores `data/config.json`. Operators follow README `data/` path — `bridge_ip` never loaded. Main README still documents community upload and GDTF on disk; code uses Patch API and local export only.

**Why it happens:** Parallel edits across branches; config path never standardized after Sekonic fields added.

**Consequences:** Remote measurement unavailable despite correct IP in wrong file; users configure `github_token` that no longer exists.

**Prevention:** Single config path documented in README, example, `load_config`, and `.gitignore`; merge Sekonic README fixes to main in P1.

**Address in phase:** **P1**, **P6**

---

### Pitfall 12: Version and manifest drift

**What goes wrong:** Runtime UI shows v0.4/v0.5; `plugin.xml` declares `Version="0.1.0"` on all branches.

**Why it happens:** Manifest not updated with releases.

**Consequences:** Plugin pool shows wrong version; support cannot match bug reports to build.

**Prevention:** Align `plugin.xml`, Lua header, README in same PR as merge.

**Address in phase:** **P1**, **P6**

---

### Pitfall 13: Extensive silent `pcall` swallowing

**What goes wrong:** Patch API, file save, path resolution, USB kernel detach wrap failures without logging or MessageBox. Bridge returns generic `meter_not_found`; plugin shows “no data.”

**Why it happens:** Defensive coding without operator-facing diagnostics.

**Consequences:** Missing fixture history, failed saves, wrong capabilities appear as empty state.

**Prevention:** Capture `pcall` errors; MessageBox on save/API failure; bridge logs USB detach failures.

**Address in phase:** **P2**, **P4**, **P5**

---

### Pitfall 14: Patch API fragility — undocumented, version-sensitive

**What goes wrong:** `DataPool`, `Groups`, `FixtureType.DMXModes.Default`, attribute naming assumed stable. First group member represents entire group (mixed fixtures → wrong make/model). `has_color_wheel_filters` true if any ColorWheel attribute exists.

**Why it happens:** No official documented Lua Patch surface; heuristics for convenience.

**Consequences:** Wrong gel hints; capability detection fails on new MA3 builds.

**Prevention:** Guard each property with `pcall`; test on real patched fixtures in P7; document MA3 version matrix.

**Address in phase:** **P5**, **P7**

---

## Minor Pitfalls

### Pitfall 15: Dead code and stale artifacts

**What goes wrong:** `base64_encode`/`base64_decode` unused (removed GitHub upload); `data/measurements/` reserved but never read/written; legacy community upload comments in Lua header.

**Prevention:** Remove dead helpers; delete or implement measurements dir; scrub stale comments in P1 merge.

**Address in phase:** **P1**, **P2**

---

### Pitfall 16: Performance — acceptable but worth documenting

**What goes wrong:** Full-file read/write on every measurement append; Patch scan loops up to 100 channels; single `/measure` lock (409 on concurrent requests).

**Prevention:** Document one client at a time; optional session-end batch write; early break on patch scan.

**Address in phase:** **P6** (docs), defer optimization post-v1

---

### Pitfall 17: Group name injection into `Cmd()`

**What goes wrong:** `select_group` interpolates user input into `Cmd('Group "'..group..'"')` without escaping `"`.

**Prevention:** Reject or sanitize delimiter characters.

**Address in phase:** **P5**, **P6**

---

## Operator Error Paths

How operators get into bad states — and which phase must design recovery UX.

| Error path | Symptom | Root cause | Recovery UX needed | Phase |
|------------|---------|------------|-------------------|-------|
| Bridge IP wrong or config in `data/` not plugin root | “Not configured” / connection timeout | Config path drift | Clear MessageBox: check path + example; Bridge Status shows last error | P6 |
| Pi offline or wrong VLAN | 38s freeze then failure | Network segmentation / blocking UI | Retry / Manual / Cancel; shorten timeout for status vs measure | P5, P6 |
| USB cable bumped mid-show | 503 until restart | No hot-plug recovery | Plugin message: “restart bridge service”; `/status` shows `connected: false` | P4, P6 |
| Operator runs HID learn_trigger on C-7000 | 2 min probe, no measure | Wizard not collapsed for bulk | Skip learn_trigger when VID known; doc says bulk-only | P4, P6 |
| CRI/R9 goals set to Skip | Still prompted for CRI/R9 | `get_measurement_params` bug | Gate prompts on session goals; same for manual fallback | P5, P6 |
| TLCI goal on FW without extended mode | Remote measure “succeeds” but TLCI nil | Field optional in bridge | goals_met treats missing TLCI per goal; UI explains FW requirement | P4, P5 |
| Bridge measure during active cueing | Console frozen | MA3 blocking socket | Warn before measure; yield where possible; don’t auto-loop without consent | P5 |
| Mixed-fixture group selected | Wrong make/model in history | First member heuristic | Warn when group fixtures disagree; pick representative or block | P5, P7 |
| User trusts auto-loop without touching fixture | No improvement after 3 attempts | No closed-loop correction | Copy: “adjust tint/gel using hints”; show delta vs target | P6, P7 |
| Manual fallback mid auto-loop | `user_manual` stuck for group | Fragmented state machine | Centralize fallback FSM; clear per-group reset | P5 |
| Accept remote reading without looking | Wrong color on air | No confirmation step | MessageBox shows CCT/Duv/CRI before commit | P5, P6 |
| Spoofed JSON on open LAN | Implausible readings | No auth on bridge | Network runbook + optional HMAC; sanity range checks | P4, P6 |

---

## Test Duplication & Coverage Traps

| Trap | What projects get wrong | Lighttune instance | Fix phase |
|------|-------------------------|-------------------|-----------|
| Copy-paste unit tests | Tests pass, production diverges | `test_color_math.lua` duplicates §2/§2b | **P3** |
| Mock-only integration | Hardware-only bugs at show | No pytest; mock always includes TLCI | **P3**, **P4** |
| No bridge client tests | Regex parse breaks on real JSON | §2c untested on host | **P3**, **P5** |
| No golden USB payloads | `_parse()` regressions on FW update | No `nr_response_2380.bin` fixture | **P3**, **P4** |
| No CI | Regressions merge unnoticed | No `.github/workflows` | **P3** |
| Manual mirror discipline | Forgotten sync after edit | README says “manually mirror” | **P3** (eliminate via require) |
| Console-only E2E | LuaSocket unavailable undetected | Zero MA3 API tests | **P7** |

---

## Merge Strategy Pitfalls

| Mistake | Outcome | Correct approach | Phase |
|---------|---------|------------------|-------|
| Merge experimental without diffing research | HID wizard + bulk driver conflict | Three-way diff 5 files; pick research bulk + experimental fixes | **P1** |
| Merge code without README/plugin.xml | Users follow dead features | Single PR: Lua + README + `plugin.xml` + `config.json.example` | **P1**, **P6** |
| Cherry-pick bridge only, not v0.5 Lua | Server works, plugin has no §2c | Merge plugin + `sekonic-bridge/` + example config together | **P1** |
| Keep two long-lived Sekonic branches | Repeated drift | Delete or archive losing branch after canonical merge | **P1** |
| Merge to main before architecture plan | Monolith locked in | P1 = snapshot for reference; P2 splits before feature additions | **P1** → **P2** |
| Trust PR #2 description alone | GDTF README regression | Grep README vs `read_capabilities_from_patch` | **P1**, **P6** |

---

## Phase-Specific Warnings

| Phase | Likely pitfall if rushed | Mitigation |
|-------|--------------------------|------------|
| **P1** | Merging wrong Sekonic snapshot | File-level diff checklist; one canonical commit hash documented in STATE.md |
| **P2** | Splitting files without MA3 multi-file packaging test | Verify `plugin.xml` ComponentLua paths on console before deleting monolith |
| **P3** | Adding CI but keeping duplicated tests | Block PR if `color_math` diverges — single source via require |
| **P4** | Shipping broad udev + HID wizard | VID/PID-only rules; bulk rename; remove learn_trigger from default path |
| **P5** | 38s blocking receive in auto-loop | Separate status timeout (5s) vs measure (≤35s); yield; operator warnings |
| **P6** | Docs fix without version bump | checklist: README, plugin.xml, Lua header, bridge README TCP not socket.http |
| **P7** | UAT on mock only | Mandatory C-7000 + real MA3 session; TLCI FW matrix noted |

---

## Cross-Cutting Themes (What MA3 + Pi + Sekonic Projects Commonly Get Wrong)

1. **Assuming the console is a general-purpose network host** — it is a UI-threaded Lua sandbox with no HTTPS and blocking sockets.
2. **Treating the Pi bridge as “just REST”** — USB bulk timing, single-meter lock, and unauthenticated LAN exposure dominate reliability more than HTTP framework choice.
3. **Naming protocols wrong (HID vs bulk)** — wastes operator time and drives incorrect udev/security posture.
4. **Optimizing for developer mock happy path** — TLCI, wizard flags, and improving CCT sequences misrepresent hardware.
5. **JSON without a library on both sides** — regex parsing is fast to write and expensive to operate.
6. **Branch + doc drift** — feature branches diverge from main and from their own README; community upload and GDTF stories are frequent casualties.
7. **Tests that don’t import production code** — duplicated Lua tests give false confidence (126 green, wrong bridge).
8. **Calibration UX without correction math** — automating meter read ≠ automating fixture convergence.
9. **Silent failure culture (`pcall` → nil)** — operators blame hardware when config path or USB detach was the issue.
10. **Show-network security as afterthought** — HTTP on `0.0.0.0` on a shared VLAN is a measurement-trigger footgun.

---

## Sources

- `.planning/PROJECT.md` — constraints, topology, active requirements
- `.planning/codebase/CONCERNS.md` — branch drift, tech debt, bugs, security, fragile areas
- `.planning/codebase/TESTING.md` — duplication pattern, mock contract, coverage gaps
- `.planning/codebase/INTEGRATIONS.md` — bridge API, USB protocol sequence
- `.planning/codebase/STACK.md` — MA3 LuaSocket constraints
- [MA Lighting Forum — Non-blocking Plugins](https://forum.malighting.com/forum/thread/7973-non-blocking-plugins/) — GMA3 coroutine/UI blocking (MEDIUM confidence)
- [kinglevel/skreader](https://github.com/kinglevel/skreader) — C-7000 bulk protocol provenance (MEDIUM — unofficial)

---

*Pitfalls research: 2026-07-01 — Pitfalls dimension for Lighttune GSD milestone*
