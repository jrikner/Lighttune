# Phase 1: Canonical Merge & Baseline - Context

**Gathered:** 2026-07-01
**Status:** Ready for planning

<domain>
## Phase Boundary

Establish a single truthful source tree on `claude/lighttune-main` by cherry-picking the full Sekonic stack from the research branch (skreader bulk protocol), aligning version strings and manifests to **v0.5.0-replan**, and rewriting README/docs for full honesty. No module splits, bridge thinning, CI, or UX refactors in this phase — only merge + baseline truth.

</domain>

<decisions>
## Implementation Decisions

### Canonical Sekonic snapshot (D-01)
- **D-01:** Cherry-pick source of truth is `origin/claude/sekonic-remote-api-research-HdMTl` (tip `5cc8bf8` — skreader SDK integration, confirmed USB bulk protocol, mock convergence).
- **D-02:** Do **not** use `origin/Lighttune-experimental` as the primary source; it lacks the skreader commit and diverges in five files (`meter_c7000_hid.py`, `meter_mock.py`, `server.py`, `SekonicCalibrator.lua`, bridge README).
- **D-03:** No hybrid reconciliation in Phase 1 unless a cherry-pick conflict forces a manual resolution — default to research-branch file contents.

### Cherry-pick scope (D-04)
- **D-04:** Land the **full Sekonic stack** on main: all six commits from research branch, oldest-first:
  1. `55aedbb` — v0.5: Add Sekonic bridge for remote measurement over network
  2. `2180070` — v0.5: GrandMA3-compliant bridge with LuaSocket TCP, auto-loop, USB discovery
  3. `96ce166` — docs: clarify curl commands run on Pi terminal, not GrandMA3 console
  4. `5091f62` — feat: add remote trigger auto-discovery (no Wireshark required)
  5. `5fb8e28` — fix: forward-declare _run_trigger_discovery; clean up stale v0.4 docs
  6. `5cc8bf8` — feat: integrate skreader SDK — confirmed USB protocol, mock convergence
- **D-05:** Includes entire `sekonic-bridge/` tree **and** v0.5 Lua HTTP client (Section 2c) plus updated `data/config.json.example` — not plugin-only.
- **D-06:** Produce a **cherry-pick manifest** documenting each commit hash, source branch, and rationale (BASE-01).

### Version label at baseline (D-07)
- **D-07:** Unified interim version string: **`v0.5.0-replan`** (brownfield replan milestone; not production v1.0).
- **D-08:** Apply consistently wherever version is declared after cherry-picks land:
  - Lua file header comment in `lua/SekonicCalibrator.lua`
  - README title/subtitle and any version callouts
  - `plugin.xml` `<Plugin Version="...">` (use `0.5.0-replan` or equivalent semver-safe label)
  - Bridge `/status` JSON `version` field if present (align or note replan suffix)
- **D-09:** Do **not** jump to v1.0.0 until Phase 7 UAT passes.

### README truth scope (D-10)
- **D-10:** **Full honesty pass** in Phase 1 — README must describe only what the code actually does after cherry-picks.
- **D-11:** **Remove or rewrite** provably false claims:
  - Community GitHub upload / `"community_upload": true` / curl-from-console upload path
  - `curl` and `unzip` as console requirements (unless code actually uses them post-merge)
  - On-disk GDTF file reading — code uses **Patch API only** (`DataPool → Groups → FixtureType`)
- **D-12:** **Add or align** truthful documentation:
  - Remote bridge workflow (Pi on show LAN, `bridge_ip` / `bridge_port` in `config.json`)
  - Manual Sekonic entry as always-available fallback
  - `config.json` lives at **plugin root** (same directory as `plugin.xml`), not inside `data/`
  - Bridge setup: curl examples run on **Pi terminal**, not GrandMA3 console
- **D-13:** HID/wizard docs may remain as-is where they reflect current v0.5 code (trigger discovery still exists); renaming/collapsing wizard is **Phase 4–6**, not Phase 1 — but do not claim features removed from code.

### Integration branch strategy (D-14)
- **D-14:** Cherry-picks apply **directly to `claude/lighttune-main`** — no long-lived `integration/*` branch and no waiting for UAT before landing baseline.
- **D-15:** GSD planning artifacts (this CONTEXT, manifest, STATE) may live on `cursor/install-gsd-core-342d`; execution merges to main in the same phase.
- **D-16:** No PR gate required for Phase 1 baseline — speed to working tree over review ceremony; document manifest for auditability instead.

### Config path (D-17, BASE-03)
- **D-17:** `load_config()` resolves `config.json` at plugin library root via `GetPath(Enums.PathType.PluginLibrary)` + `config.json` — **not** `data/config.json`.
- **D-18:** README and `data/config.json.example` comments must state: copy example to **`config.json` at plugin root**; runtime paths like `data/fixture_log.json` stay under `data/`.

### Claude's Discretion
- Exact `plugin.xml` Version attribute format if MA3 rejects non-semver strings (fallback: `0.5.0` with replan noted in README/Lua header only).
- Cherry-pick manifest file name/location (recommend `.planning/phases/01-canonical-merge-baseline/01-CHERRY-PICK-MANIFEST.md`).
- Order of operations: cherry-picks first, then version/doc alignment commit, or single atomic PR-style commit series on main.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & roadmap
- `.planning/ROADMAP.md` — Phase 1 goal, success criteria, BASE-01/02/03
- `.planning/REQUIREMENTS.md` — BASE-01, BASE-02, BASE-03 definitions
- `.planning/PROJECT.md` — cherry-pick strategy, single-plugin + thin bridge decisions

### Codebase intelligence
- `.planning/codebase/_BRANCH-SCOPE.md` — branch tips and file deltas
- `.planning/codebase/CONCERNS.md` — branch drift, README lies, HID vs bulk naming
- `.planning/codebase/STACK.md` — branch matrix (main vs Sekonic)
- `.planning/codebase/CONVENTIONS.md` — v0.4 vs v0.5 Lua deltas, config keys

### Research & pitfalls
- `.planning/research/PITFALLS.md` — Pitfall 1 (wrong branch merge), doc/manifest drift
- `.planning/research/SUMMARY.md` — Phase 1 rationale

### Source branches (read-only reference during cherry-pick)
- `origin/claude/lighttune-main` — merge target (v0.4 baseline)
- `origin/claude/sekonic-remote-api-research-HdMTl` — **cherry-pick source** (6 commits)

### External protocol
- [kinglevel/skreader](https://github.com/kinglevel/skreader) — C-7000 USB bulk protocol (integrated in 5cc8bf8)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `origin/claude/lighttune-main`: v0.4 `lua/SekonicCalibrator.lua` (~1431 lines), `test_color_math.lua` (126 tests), honest Patch-API README sections on main (partial).
- Research branch adds: `sekonic-bridge/` (13 files, ~2448 lines), v0.5 Lua Section 2c HTTP client, `bridge_ip`/`bridge_port` in config example.

### Established Patterns
- Cherry-pick, not wholesale merge — avoids experimental/research conflict snapshot.
- Config at plugin root — `load_config()` in Section 5 uses `PluginLibrary` path + `config.json`.
- Version drift today: `plugin.xml` says `0.1.0`, Lua header says v0.4/v0.5 — Phase 1 must reconcile to v0.5.0-replan.

### Integration Points
- After Phase 1, `claude/lighttune-main` must contain both v0.4-caliber color math **and** v0.5 bridge client + `sekonic-bridge/` for Phases 2–7 to build on.
- Phase 4 may parallelize bridge thinning; Phase 1 delivers the research-branch tree as-is.

</code_context>

<specifics>
## Specific Ideas

- User explicitly chose **skreader research branch** over experimental — skreader bulk protocol is non-negotiable.
- User wants **everything on main immediately** until a working base exists — optimize for integrator clone-from-main, not branch archaeology.
- Interim version **v0.5.0-replan** signals replan milestone without claiming production v1 ship.

</specifics>

<deferred>
## Deferred Ideas

- Collapse HID trigger-discovery wizard / rename `meter_c7000_hid.py` → bulk naming — **Phase 4–6**
- Module split (`color_math.lua`, etc.) — **Phase 2**
- Bridge API key auth (MTR-08) — **Phase 4**
- Iterative closed-loop correction (CAL-07) — **v2**
- Experimental-branch-only refactors in `meter_c7000_hid.py` / mock meter — evaluate only if cherry-pick conflicts arise

</deferred>

---

*Phase: 1-Canonical Merge & Baseline*
*Context gathered: 2026-07-01*
