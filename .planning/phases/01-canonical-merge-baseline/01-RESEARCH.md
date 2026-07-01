# Phase 1: Canonical Merge & Baseline - Research

**Researched:** 2026-07-01  
**Domain:** Git cherry-pick merge, GrandMA3 Lua plugin baseline, sekonic-bridge Python stack, doc/manifest alignment  
**Confidence:** HIGH

## Summary

Phase 1 lands the full Sekonic v0.5 stack from `origin/claude/sekonic-remote-api-research-HdMTl` (tip `5cc8bf8`) onto `origin/claude/lighttune-main` (tip `df95d17`) via six ordered cherry-picks — not a wholesale merge and not `Lighttune-experimental` (which lacks the skreader commit `5cc8bf8`) [VERIFIED: git log / merge-base].

The merge surface is **13 files, +2448 / −55 lines** between branch tips: entire `sekonic-bridge/` tree (10 files), `lua/SekonicCalibrator.lua` (+657 lines, v0.4→v0.5), `data/config.json.example`, and `README.md` [VERIFIED: `git diff --stat`]. Cherry-pick commit 1 conflicts on `data/config.json.example` and `lua/SekonicCalibrator.lua` when applied to main without a merge strategy; all six commits apply cleanly with `-X theirs`, after which **Lua matches research tip exactly** and only `README.md` differs — and that difference is favorable (main-retained Patch API section vs research branch’s on-disk GDTF path) [VERIFIED: simulated cherry-pick on temp branch].

Post-cherry-pick work is mandatory for BASE-02/03: unified version **`v0.5.0-replan`**, README honesty pass (community-upload line, wrong `data/config.json` copy path, bridge workflow), `plugin.xml` Version, bridge `/status` version field, and `.gitignore` alignment for plugin-root `config.json`. `load_config()` on both main and research already resolves **`GetPath(PluginLibrary)/config.json`** — code is correct; docs and `.gitignore` are wrong [VERIFIED: `git show …:lua/SekonicCalibrator.lua` grep].

**Primary recommendation:** Cherry-pick six commits oldest-first onto `claude/lighttune-main` with research-branch wins on conflicts (`-X theirs` or manual `-theirs`), verify tree parity (`git diff` vs `5cc8bf8` except README), then a single follow-up commit for v0.5.0-replan + README/config/.gitignore truth pass + cherry-pick manifest (BASE-01).

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Canonical Sekonic snapshot (D-01)
- **D-01:** Cherry-pick source of truth is `origin/claude/sekonic-remote-api-research-HdMTl` (tip `5cc8bf8` — skreader SDK integration, confirmed USB bulk protocol, mock convergence).
- **D-02:** Do **not** use `origin/Lighttune-experimental` as the primary source; it lacks the skreader commit and diverges in five files (`meter_c7000_hid.py`, `meter_mock.py`, `server.py`, `SekonicCalibrator.lua`, bridge README).
- **D-03:** No hybrid reconciliation in Phase 1 unless a cherry-pick conflict forces a manual resolution — default to research-branch file contents.

#### Cherry-pick scope (D-04)
- **D-04:** Land the **full Sekonic stack** on main: all six commits from research branch, oldest-first:
  1. `55aedbb` — v0.5: Add Sekonic bridge for remote measurement over network
  2. `2180070` — v0.5: GrandMA3-compliant bridge with LuaSocket TCP, auto-loop, USB discovery
  3. `96ce166` — docs: clarify curl commands run on Pi terminal, not GrandMA3 console
  4. `5091f62` — feat: add remote trigger auto-discovery (no Wireshark required)
  5. `5fb8e28` — fix: forward-declare _run_trigger_discovery; clean up stale v0.4 docs
  6. `5cc8bf8` — feat: integrate skreader SDK — confirmed USB protocol, mock convergence
- **D-05:** Includes entire `sekonic-bridge/` tree **and** v0.5 Lua HTTP client (Section 2c) plus updated `data/config.json.example` — not plugin-only.
- **D-06:** Produce a **cherry-pick manifest** documenting each commit hash, source branch, and rationale (BASE-01).

#### Version label at baseline (D-07)
- **D-07:** Unified interim version string: **`v0.5.0-replan`** (brownfield replan milestone; not production v1.0).
- **D-08:** Apply consistently wherever version is declared after cherry-picks land:
  - Lua file header comment in `lua/SekonicCalibrator.lua`
  - README title/subtitle and any version callouts
  - `plugin.xml` `<Plugin Version="...">` (use `0.5.0-replan` or equivalent semver-safe label)
  - Bridge `/status` JSON `version` field if present (align or note replan suffix)
- **D-09:** Do **not** jump to v1.0.0 until Phase 7 UAT passes.

#### README truth scope (D-10)
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

#### Integration branch strategy (D-14)
- **D-14:** Cherry-picks apply **directly to `claude/lighttune-main`** — no long-lived `integration/*` branch and no waiting for UAT before landing baseline.
- **D-15:** GSD planning artifacts (this CONTEXT, manifest, STATE) may live on `cursor/install-gsd-core-342d`; execution merges to main in the same phase.
- **D-16:** No PR gate required for Phase 1 baseline — speed to working tree over review ceremony; document manifest for auditability instead.

#### Config path (D-17, BASE-03)
- **D-17:** `load_config()` resolves `config.json` at plugin library root via `GetPath(Enums.PathType.PluginLibrary)` + `config.json` — **not** `data/config.json`.
- **D-18:** README and `data/config.json.example` comments must state: copy example to **`config.json` at plugin root**; runtime paths like `data/fixture_log.json` stay under `data/`.

### Claude's Discretion
- Exact `plugin.xml` Version attribute format if MA3 rejects non-semver strings (fallback: `0.5.0` with replan noted in README/Lua header only).
- Cherry-pick manifest file name/location (recommend `.planning/phases/01-canonical-merge-baseline/01-CHERRY-PICK-MANIFEST.md`).
- Order of operations: cherry-picks first, then version/doc alignment commit, or single atomic PR-style commit series on main.

### Deferred Ideas (OUT OF SCOPE)
- Collapse HID trigger-discovery wizard / rename `meter_c7000_hid.py` → bulk naming — **Phase 4–6**
- Module split (`color_math.lua`, etc.) — **Phase 2**
- Bridge API key auth (MTR-08) — **Phase 4**
- Iterative closed-loop correction (CAL-07) — **v2**
- Experimental-branch-only refactors in `meter_c7000_hid.py` / mock meter — evaluate only if cherry-pick conflicts arise
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BASE-01 | Cherry-pick proven commits from experimental branches onto main (document manifest; not wholesale branch merge) | Six-commit ordered list verified on research branch; conflict files identified; `-X theirs` procedure produces Lua/bridge parity with tip `5cc8bf8`; manifest template path recommended |
| BASE-02 | README, `plugin.xml`, version strings, and `config.json.example` match implementation (no false community-upload or disk-GDTF claims) | Post-cherry-pick README audit: remaining false claims listed; Patch API section already correct after cherry-pick onto main; version drift inventory (`0.1.0` plugin.xml, v0.5 Lua header, bridge `1.0.0`) |
| BASE-03 | `config.json` path documented and consistent between README and plugin code | `load_config()` at plugin root verified on main and research; README/config.example/.gitignore mismatches documented with fix checklist |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Cherry-pick / canonical tree | Git / repo layout | — | Phase 1 is source-control integration, not runtime |
| Color math + session UX (v0.4 baseline) | GrandMA3 plugin (Lua) | Host tests (`test_color_math.lua`) | Unchanged behavior preserved from main through merge |
| Bridge HTTP client (Section 2c) | GrandMA3 plugin (Lua) | Pi bridge (transport) | Console owns orchestration; cherry-pick adds client |
| USB meter I/O + REST API | Pi bridge (Python/FastAPI) | systemd on Pi | Entire `sekonic-bridge/` lands via cherry-pick |
| Version + doc truth | Repo manifests (README, plugin.xml, examples) | GSD manifest artifact | BASE-02/03 compliance layer after code lands |
| Fixture DB persistence | Plugin `data/fixture_log.json` | — | Path unchanged; not part of merge conflict surface |

## Standard Stack

Phase 1 does **not** introduce new dependencies — it cherry-picks existing pins. Preserve research-branch versions.

### Core (cherry-picked unchanged)

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| GrandMA3 Lua runtime | DataVersion `1.6.1.3` [VERIFIED: `plugin.xml`] | Plugin host | Project baseline |
| Lua 5.4 (host tests) | CLI `lua5.4` [VERIFIED: `test_color_math.lua` header] | Color math regression | 115+ assertions in standalone harness |
| `fastapi` | `0.115.0` [VERIFIED: `sekonic-bridge/requirements.txt` on research branch] | Bridge REST API | Existing research-branch pin |
| `uvicorn[standard]` | `0.32.0` [VERIFIED: requirements.txt] | ASGI server | Existing research-branch pin |
| `pyusb` | `1.3.1` [VERIFIED: requirements.txt] | C-7000 USB bulk I/O | skreader-derived driver |
| LuaSocket (`socket`) | Console-provided [VERIFIED: AGENTS.md / v0.5 Section 2c] | TCP HTTP/1.0 to bridge | Validated pattern on research branch |

### Supporting

| Component | Version | Purpose | When to Use |
|-----------|---------|---------|-------------|
| `git cherry-pick` | system git 2.43+ [VERIFIED: environment] | Ordered"Apply six commits oldest-first"` | Phase 1 primary merge mechanism |
| kinglevel/skreader protocol | MIT reference [CITED: https://github.com/kinglevel/skreader] | C-7000 bulk sequence in `meter_c7000_hid.py` | Integrated in commit `5cc8bf8` |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Cherry-pick research branch | Merge `Lighttune-experimental` | Experimental lacks `5cc8bf8`; five-file driver/Lua drift — **rejected per D-02** |
| Cherry-pick | Wholesale branch merge | Higher conflict noise; violates BASE-01 / PROJECT.md — **rejected** |
| `-X theirs` on conflicts | Manual `-theirs` per hunk | Equivalent outcome for commit 1; manual preferred if reviewer wants explicit audit trail |

## Package Legitimacy Audit

> Cherry-pick lands existing pins; no new installs in Phase 1. Audit for planner awareness in Phase 4 Pi setup.

| Package | Registry | Pinned | Source Repo | Verdict | Disposition |
|---------|----------|--------|-------------|---------|-------------|
| `fastapi` | PyPI | 0.115.0 | github.com/fastapi/fastapi | SUS (seam: too-new signal) | Keep pinned version from research branch |
| `uvicorn` | PyPI | 0.32.0 | github.com/Kludex/uvicorn | SUS (seam: too-new signal) | Keep pinned version from research branch |
| `pyusb` | PyPI | 1.3.1 | github.com/pyusb/pyusb | SUS (seam: unknown-downloads) | Keep pinned version from research branch |

**Packages removed due to SLOP verdict:** none  
**Packages flagged as suspicious [SUS]:** fastapi, uvicorn, pyusb — already pinned in cherry-picked tree; no Phase 1 install step

## Architecture Patterns

### System Architecture Diagram (post Phase 1)

```text
┌─────────────────────┐     HTTP/1.0 TCP      ┌──────────────────────┐
│  GrandMA3 Console   │ ◄──────────────────► │  Raspberry Pi        │
│  SekonicCalibrator  │   LuaSocket :8765    │  sekonic-bridge/     │
│  (v0.5 Lua §2c)     │                      │  FastAPI + pyusb     │
└─────────┬───────────┘                      └──────────┬───────────┘
          │                                             │ USB bulk
          │ Patch API / SetColor                        ▼
          ▼                                    ┌──────────────────────┐
   Fixture groups                             │  Sekonic C-7000        │
   data/fixture_log.json                      └──────────────────────┘
   config.json (plugin root)
```

### Recommended Post-Merge Tree

```text
SekonicCalibrator/
├── plugin.xml
├── config.json              ← runtime (gitignored); copy from example
├── lua/SekonicCalibrator.lua  ← v0.5 + Section 2c
├── data/
│   ├── config.json.example    ← bridge_ip, bridge_port, github_username
│   └── fixture_log.json       ← runtime append-only DB
├── test_color_math.lua
└── sekonic-bridge/            ← full Python stack (10 files)
    ├── server.py
    ├── meter_c7000_hid.py
    ├── meter_mock.py
    └── …
```

### Pattern 1: Ordered cherry-pick with research-branch conflict wins

**What:** Apply six commits sequentially onto main; on conflict, take incoming (research) content.  
**When to use:** D-03 default; commit 1 always touches `lua/SekonicCalibrator.lua` and `data/config.json.example`.  
**Example:**

```bash
git checkout claude/lighttune-main
git pull origin claude/lighttune-main
git cherry-pick 55aedbb 2180070 96ce166 5091f62 5fb8e28 5cc8bf8 -X theirs
```

[VERIFIED: simulated on temp branch — all six commits apply, exit 0]

### Pattern 2: Post-cherry-pick tree parity check

**What:** Confirm code matches research tip before doc/version commit.  
**When to use:** Gate before BASE-02 edits.

```bash
git diff origin/claude/sekonic-remote-api-research-HdMTl -- \
  lua/SekonicCalibrator.lua sekonic-bridge/ data/config.json.example plugin.xml
# Expect: no output (README may differ — acceptable)
```

[VERIFIED: after `-X theirs` cherry-pick, Lua diff vs tip = 0 lines]

### Pattern 3: Plugin-root config (BASE-03)

**What:** `load_config()` already uses plugin library root — docs must match.

```lua
local function load_config()
    local dir = get_plugin_dir()
    if not dir then return nil end
    local path = dir .. get_sep() .. "config.json"
    -- research branch also parses bridge_ip, bridge_port (default 8765)
end
```

[VERIFIED: `git show origin/claude/lighttune-main:lua/...` lines 1245–1252; research lines 1704–1717]

### Anti-Patterns to Avoid

- **Merging `Lighttune-experimental`:** lacks skreader commit — wrong USB driver generation [VERIFIED: `git merge-base --is-ancestor 5cc8bf8 origin/Lighttune-experimental` → false]
- **Cherry-picking bridge only:** leaves main on v0.4 Lua without Section 2c — remote measure broken
- **Trusting research README GDTF section verbatim:** on-disk GDTF path is false; cherry-pick onto main already retains Patch API section — keep that, fix config path instead
- **Updating `plugin.xml` without Lua header / README:** version drift persists (Pitfall 12)

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Merge Sekonic stack | Custom file copy from experimental | Git cherry-pick from research branch | Preserves commit provenance for BASE-01 manifest |
| USB C-7000 protocol | New reverse-engineering | skreader-derived `meter_c7000_hid.py` in `5cc8bf8` | Already integrated and tested on research branch |
| HTTP client on MA3 | curl / io.popen | LuaSocket TCP HTTP/1.0 (Section 2c) | Platform constraint — no shell/HTTPS [VERIFIED: main removed curl in 0530fd2] |
| JSON config parsing | New JSON library in Phase 1 | Existing regex `load_config()` from research branch | Module extraction deferred to Phase 2 (ARCH-02) |
| Version labeling | Ad-hoc per-file strings | Single `v0.5.0-replan` pass across Lua header, README, plugin.xml, bridge `/status` | BASE-02 requirement |

**Key insight:** Phase 1 is integration and truth-telling, not refactoring. Take research-branch code as-is; fix only docs, manifests, and `.gitignore` paths.

## Cherry-Pick Procedure Recommendations

### Commit manifest (BASE-01)

| Order | Hash | Subject | Files touched (high signal) |
|-------|------|---------|----------------------------|
| 1 | `55aedbb` | v0.5: Add Sekonic bridge | **CONFLICT** `lua/SekonicCalibrator.lua`, `data/config.json.example`; adds entire `sekonic-bridge/` (9 files) |
| 2 | `2180070` | LuaSocket TCP, auto-loop, USB discovery | Large Lua rewrite; `discover_device.py`; `server.py`, `meter_c7000_hid.py` |
| 3 | `96ce166` | curl on Pi, not console | `README.md`, `sekonic-bridge/README.md` |
| 4 | `5091f62` | Remote trigger auto-discovery | Lua, `server.py`, `meter_c7000_hid.py`, bridge README |
| 5 | `5fb8e28` | Forward-decl fix; stale v0.4 docs | `README.md`, `data/config.json.example`, Lua (+1 line) |
| 6 | `5cc8bf8` | skreader SDK integration | `meter_c7000_hid.py`, `meter_mock.py`, `server.py`, bridge README, Lua |

[VERIFIED: `git log --reverse main..research` + `git show --stat` per commit]

### Conflict expectations

| Commit | Conflicts on main (default) | Resolution policy (D-03) |
|--------|----------------------------|--------------------------|
| `55aedbb` | `lua/SekonicCalibrator.lua`, `data/config.json.example` | Take research branch (theirs / `-X theirs`) |
| `2180070`–`5cc8bf8` | None observed in simulation | N/A |

[VERIFIED: default cherry-pick stops at commit 1 with UU on two files; `-X theirs` completes all six]

### Recommended execution sequence

1. **Checkout merge target:** `git checkout claude/lighttune-main && git pull`
2. **Cherry-pick:** `git cherry-pick 55aedbb 2180070 96ce166 5091f62 5fb8e28 5cc8bf8 -X theirs`  
   - If avoiding strategy flag: resolve commit 1 manually with `git checkout --theirs` on both conflicted files, then `git cherry-pick --continue`
3. **Parity check:** `git diff origin/claude/sekonic-remote-api-research-HdMTl -- lua/ sekonic-bridge/ data/config.json.example` → empty
4. **Doc/version commit (BASE-02/03):** README honesty, `v0.5.0-replan`, `plugin.xml`, config example header comments, `.gitignore` for root `config.json`
5. **Write manifest:** `.planning/phases/01-canonical-merge-baseline/01-CHERRY-PICK-MANIFEST.md` listing all six hashes, source branch, rationale, conflict notes
6. **Push to `claude/lighttune-main`** per D-14 (no integration branch)

### Post-cherry-pick README fixes required (BASE-02)

Even after successful cherry-pick onto main, README still needs edits [VERIFIED: grep post-cherry-pick tree]:

| Issue | Location | Fix |
|-------|----------|-----|
| "optionally uploaded … GitHub" | Overview § | Remove; state local export only |
| Feature table "GDTF file" for manufacturer CCT/CRI | Features table | Patch API / FixtureType wording |
| `Copy data/config.json.example → data/config.json` | Config section | **Plugin root:** `config.json` next to `plugin.xml` |
| Missing bridge workflow section | Requirements / Features | Add Pi LAN, `bridge_ip`, manual fallback, Bridge Status menu |
| Title still "v0.4" | Header | `v0.5.0-replan` |

**Keep:** Fixture Capability Detection section (Patch API) — cherry-pick onto main preserves correct content vs research tip’s on-disk GDTF section [VERIFIED: README diff vs `5cc8bf8`].

### `.gitignore` fix (BASE-03)

Current repo ignores `data/config.json` only [VERIFIED: `.gitignore`]. Runtime path is plugin-root `config.json`. Add `/config.json` or `config.json` at plugin root; keep example at `data/config.json.example` with comment directing copy target.

## Common Pitfalls

### Pitfall 1: Wrong Sekonic snapshot (PITFALLS.md #1)

**What goes wrong:** Merging experimental branch lands pre-skreader driver.  
**Why it happens:** PR #2 merged research into experimental before `5cc8bf8`.  
**How to avoid:** Cherry-pick only the six commits ending at `5cc8bf8`; manifest documents source branch.  
**Warning signs:** `meter_c7000_hid.py` lacks skreader byte offsets; mock lacks convergence tables.

[VERIFIED: experimental tip `83f74b8` is not ancestor of `5cc8bf8`]

### Pitfall 2: Cherry-pick plugin without bridge (PITFALLS merge table)

**What goes wrong:** HTTP client in Lua with no `sekonic-bridge/` on main.  
**How to avoid:** Commit `55aedbb` adds both; verify `sekonic-bridge/server.py` exists after pick 1.

### Pitfall 3: Config path drift (PITFALLS #11, BASE-03)

**What goes wrong:** Operator copies example to `data/config.json`; `bridge_ip` never loaded.  
**How to avoid:** Fix README, example comments, `.gitignore` in same commit as version alignment.  
**Warning signs:** `load_config()` returns nil bridge fields despite configured IP.

[VERIFIED: research README lines 288–289 still say `data/config.json`]

### Pitfall 4: Doc merge without code merge (BASE-02)

**What goes wrong:** README claims community upload while Lua has no upload path on main post-0530fd2.  
**How to avoid:** Grep README for `community_upload`, `curl`, `unzip`, on-disk GDTF paths after cherry-pick.

### Pitfall 5: Version manifest drift

**What goes wrong:** `plugin.xml` stays `0.1.0`, Lua header v0.5, README v0.4.  
**How to avoid:** Single D-08 pass to `v0.5.0-replan` (or `0.5.0` in plugin.xml if MA3 rejects suffix).

[VERIFIED: both branch tips have `plugin.xml` Version=`0.1.0`]

### Pitfall 6: Accepting research README GDTF section blindly

**What goes wrong:** Documents on-disk GDTF read; code uses Patch API only.  
**How to avoid:** After cherry-pick onto main, **retain** Patch API README section (already present); do not revert to research tip README wholesale.

## Code Examples

### Verification: load_config path (BASE-03)

```lua
-- Research branch after cherry-pick (Section 5)
local function load_config()
    local dir = get_plugin_dir()
    if not dir then return nil end
    local path = dir .. get_sep() .. "config.json"
    local f = io.open(path, "r"); if not f then return nil end
    local content = f:read("*a"); f:close()
    local username    = content:match('"github_username"%s*:%s*"([^"]+)"')
    local bridge_ip   = content:match('"bridge_ip"%s*:%s*"([^"]+)"')
    local bridge_port = tonumber(content:match('"bridge_port"%s*:%s*(%d+)'))
    return {
        github_username = username,
        bridge_ip       = bridge_ip,
        bridge_port     = bridge_port or 8765,
    }
end
```

Source: [VERIFIED: `git show 5cc8bf8:lua/SekonicCalibrator.lua`]

### config.json.example header comment (target state)

```json
{
  "_comment": "Copy this file to config.json at the plugin root (same folder as plugin.xml), NOT to data/config.json",
  "github_username": "your_github_username",
  "bridge_ip":         "192.168.1.50",
  "bridge_port":       8765
}
```

[ASSUMED: `_comment` key acceptable in regex parser — parser ignores unknown keys; confirm no MA3 JSON strictness requirement]

### Bridge status version alignment (D-08)

```python
# server.py /status response (research branch)
"version": "1.0.0-replan",  # or "0.5.0-replan" — align with milestone label
```

[VERIFIED: current field is `"version": "1.0.0"` at line ~179 on research branch]

## Verification Commands

### Git / cherry-pick gates

```bash
# Confirm six commits exist on research branch, not on main
git log --oneline --reverse origin/claude/lighttune-main..origin/claude/sekonic-remote-api-research-HdMTl

# Confirm experimental lacks skreader tip
git merge-base --is-ancestor 5cc8bf8 origin/Lighttune-experimental && echo BAD || echo OK

# After cherry-pick: code parity with research tip
git diff origin/claude/sekonic-remote-api-research-HdMTl -- \
  lua/SekonicCalibrator.lua sekonic-bridge/ data/config.json.example plugin.xml

# sekonic-bridge present on main
test -f sekonic-bridge/server.py && test -f sekonic-bridge/meter_c7000_hid.py

# Section 2c present in Lua
grep -n "BRIDGE NETWORKING" lua/SekonicCalibrator.lua
grep -n "_http_request" lua/SekonicCalibrator.lua

# Version strings (post alignment commit)
grep -n "v0.5.0-replan\|Version=" README.md plugin.xml lua/SekonicCalibrator.lua | head -20
```

### Doc truth gates (BASE-02)

```bash
# Must return NO matches after honesty pass
grep -n "community_upload\|io.popen\|curl.*console\|unzip.*GDTF" README.md
grep -n "gma3_library/gdtf" README.md   # on-disk GDTF path

# Must return matches after fix
grep -n "Patch API\|plugin root\|bridge_ip" README.md data/config.json.example
```

### Config path gates (BASE-03)

```bash
# Code: plugin root only
grep -A5 "local function load_config" lua/SekonicCalibrator.lua | grep config.json

# Docs: must NOT instruct data/config.json for runtime config
grep -n "data/config.json" README.md data/config.json.example

# gitignore covers plugin root config
grep config.json .gitignore
```

### Color math regression (preserves v0.4 baseline)

```bash
lua5.4 test_color_math.lua
# Expect: all PASS, 0 FAIL (115+ assertions)
```

[VERIFIED: test file exists; `lua5.4` not installed in research VM — install required for execution]

### Bridge smoke (optional post-merge, not Phase 1 gate)

```bash
cd sekonic-bridge && python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
./venv/bin/python3 server.py --mock --port 8765 &
curl -s http://localhost:8765/status | grep -E '"connected"|"version"'
curl -s -X POST http://localhost:8765/measure | grep cct
```

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Standalone Lua 5.4 harness (`test_color_math.lua`) |
| Config file | none |
| Quick run command | `lua5.4 test_color_math.lua` |
| Full suite command | same (single file) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BASE-01 | v0.4 color math preserved after merge | unit | `lua5.4 test_color_math.lua` | ✅ |
| BASE-01 | sekonic-bridge tree present | git/tree | `test -f sekonic-bridge/server.py` | ✅ after cherry-pick |
| BASE-02 | No false README claims | grep audit | `! grep -q community_upload README.md` | manual script |
| BASE-03 | Config path code/docs match | grep | see Verification Commands | ✅ code; ❌ docs until fix |

### Sampling Rate

- **Per cherry-pick commit:** `git diff --stat HEAD~1` + conflict file review
- **Post all six picks:** tree parity diff vs `5cc8bf8`
- **Phase gate:** `lua5.4 test_color_math.lua` green + doc grep gates + manifest written

### Wave 0 Gaps

- [ ] `lua5.4` on dev/CI host — not present in research environment [VERIFIED: `command -v lua5.4` failed]
- [ ] Bridge pytest — Phase 3 (TST-02); not required for Phase 1 gate
- [ ] Root `config.json` in `.gitignore` — must add in alignment commit

## Security Domain

Phase 1 lands unauthenticated HTTP bridge from research branch — no new auth. Document for operator awareness; MTR-08 deferred to Phase 4.

### Applicable ASVS Categories (ASVS L1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V2 Authentication | no (Phase 1) | Bridge auth deferred Phase 4 |
| V5 Input Validation | partial | Regex JSON parse unchanged; hardened in Phase 2 |
| V6 Cryptography | no | No HTTPS on MA3; show LAN trust model documented |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Unauthenticated `/measure` on show LAN | Tampering | Document VLAN isolation; Phase 4 API key |
| Cleartext HTTP MITM | Spoofing | Trusted show network; operator confirms readings |
| Secrets in git | Information disclosure | `config.json` gitignored at plugin root |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| git | Cherry-pick | ✓ | 2.43.0 | — |
| python3 | Bridge smoke test | ✓ | 3.12.3 | Skip smoke; tree check only |
| lua5.4 | Color math tests | ✗ | — | Install via apt/distro package before gate |
| GrandMA3 console | Runtime | ✗ (dev VM) | — | Phase 7 UAT |

**Missing dependencies with no fallback:**
- None blocking cherry-pick (git-only merge)

**Missing dependencies with fallback:**
- `lua5.4` — install on executor host before claiming Phase 1 complete

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual meter entry only (main v0.4) | Remote bridge + manual fallback (v0.5) | research commits 55aedbb–5cc8bf8 | Phase 1 lands v0.5 on main |
| HID trigger discovery prototype | skreader USB bulk in `5cc8bf8` | research tip | Use research branch, not experimental |
| Community GitHub upload (removed 0530fd2) | Local export only | main commit 0530fd2 | README must catch up in Phase 1 |

**Deprecated/outdated:**
- On-disk GDTF reading in README — code never did this post-Patch API; research README regressed, cherry-pick onto main fixes section

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | MA3 `plugin.xml` accepts `Version="0.5.0-replan"` | User Constraints / D-08 | Fallback to `0.5.0` per discretion |
| A2 | `_comment` key in config example is harmless to regex parser | Code Examples | Remove if parser breaks |
| A3 | `-X theirs` during cherry-pick equals D-03 “research branch wins” | Cherry-pick Procedure | Use explicit `checkout --theirs` if policy disputed |

## Open Questions

1. **plugin.xml semver suffix**
   - What we know: D-08 wants `0.5.0-replan`; discretion allows `0.5.0` only in XML
   - What's unclear: MA3 parser behavior for non-semver Version strings
   - Recommendation: Try `0.5.0-replan`; fallback `0.5.0` with replan in Lua/README only

2. **Bridge `/status` version string**
   - What we know: Currently `"1.0.0"` independent of plugin version
   - Recommendation: Use `"0.5.0-replan"` or `"1.0.0-replan"` consistently; document in manifest

## Sources

### Primary (HIGH confidence)
- Git simulation on `origin/claude/lighttune-main` — cherry-pick conflicts, `-X theirs` success, tree diff vs `5cc8bf8`
- `git show` / `git diff` on branch tips — file lists, `load_config()` paths, README claims
- `.planning/phases/01-canonical-merge-baseline/01-CONTEXT.md` — locked decisions
- `.planning/codebase/_BRANCH-SCOPE.md`, `CONCERNS.md` — branch drift inventory
- `.planning/research/PITFALLS.md` — Phase 1 pitfalls

### Secondary (MEDIUM confidence)
- [kinglevel/skreader](https://github.com/kinglevel/skreader) — USB bulk protocol provenance (commit `5cc8bf8`)

### Tertiary (LOW confidence)
- MA3 `plugin.xml` Version attribute format — not validated on physical console in this session [ASSUMED fallback documented]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — pinned versions read from research branch requirements.txt
- Architecture: HIGH — git simulation confirms merge procedure and tree shape
- Pitfalls: HIGH — cross-checked PITFALLS.md with live git state

**Research date:** 2026-07-01  
**Valid until:** 2026-07-31 (stable brownfield merge; branch tips may advance)
