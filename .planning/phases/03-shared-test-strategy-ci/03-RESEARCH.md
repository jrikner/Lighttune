# Phase 3: Shared Test Strategy & CI - Research

**Researched:** 2026-07-02  
**Domain:** Host Lua test runner split, golden JSON fixtures, FastAPI bridge route tests, GitHub Actions CI  
**Confidence:** HIGH (Phase 2 domain trio + 133 PASS baseline verified on workspace; bridge routes and MockMeter contract read from source; CI layout follows STACK.md and CONTEXT D-40–D-54)

## Summary

Phase 3 turns the post–Phase 2 **monolithic** `test_color_math.lua` (133 PASS, 0 FAIL) into a **unified host runner** under `tests/` and adds **automated bridge route tests** plus **GitHub Actions** so regressions on shared modules and the Pi HTTP contract are caught before Phase 4–5 feature work resumes.

The workspace already satisfies Phase 2 prerequisites: `lua/color_math.lua`, `lua/fixture_db.lua`, and `lua/goals.lua` export `return M` tables; the root test file `require`s them via `package.path = package.path .. ";./lua/?.lua"` and covers **17 test sections** across color math (~6 sections, ~45 assertions), fixture DB (~9 sections, ~75 assertions), and goals (~2 sections, ~13 assertions) [VERIFIED: `lua5.4 test_color_math.lua` → 133 passed].

**Primary recommendation:** Implement CONTEXT decisions D-40–D-54:

1. Add `tests/run.lua` as the CI entry point; split domain suites into `tests/test_color_math.lua`, `tests/test_fixture_db.lua`, `tests/test_goals.lua` with a shared assertion harness in `tests/lib/harness.lua`.
2. Keep root `test_color_math.lua` as a **thin wrapper** (`dofile("tests/run.lua")` or equivalent) — no duplicated test logic (D-34 carry-forward).
3. Add `tests/fixtures/` golden JSON for bridge responses and the quoted-make fixture DB edge case; compare **keys, types, and value ranges** — skip `uptime_s`, `timestamp`, and jittered mock fields (D-49).
4. Add `sekonic-bridge/requirements-dev.txt` with `pytest` and `httpx`; test `/status`, `/measure`, `/discover` only using **mock meter** via `httpx.ASGITransport` (preferred) or Starlette `TestClient` (acceptable per D-50 discretion).
5. Add `.github/workflows/ci.yml` with parallel **host-lua** and **bridge-pytest** jobs on `ubuntu-latest` (D-51–D-53).

No Pi hardware, no MA3 console, and no `/capture` or `/learn_trigger` CI gates in this phase.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Host test layout (D-40)
- **D-40:** Create `tests/` directory with **`tests/run.lua`** as the single host entry point (TST-01).
- **D-41:** Split domain tests into `tests/test_color_math.lua`, `tests/test_fixture_db.lua`, `tests/test_goals.lua` — each `require`s shared modules from `lua/`.
- **D-42:** Keep **`test_color_math.lua` at repo root** as a thin wrapper that invokes `tests/run.lua` or delegates to it (backward compat for README/docs); root file must not duplicate logic (D-34 carry-forward).

#### Assertion baseline (D-43)
- **D-43:** CI must preserve **133+ PASS** (current post–Phase 2 count); ROADMAP "126+" is minimum floor, not regression target.
- **D-44:** `tests/run.lua` sets `package.path` to `./lua/?.lua` and exits non-zero on any FAIL.

#### Bridge test stack (D-45)
- **D-45:** Use **pytest + httpx** for bridge route tests (TST-02); add `pytest`, `httpx` to bridge dev dependencies (separate from Pi runtime `requirements.txt` or as `sekonic-bridge/requirements-dev.txt`).
- **D-46:** Bridge tests start server with **`--mock`** flag; no USB hardware in CI.
- **D-47:** Test **`GET /status`**, **`POST /measure`**, **`GET /discover`** only — the three routes in ROADMAP Phase 3 success criteria. Do not require `/capture` or `/learn_trigger` to pass CI.

#### Golden fixtures (D-48)
- **D-48:** Store golden JSON under **`tests/fixtures/`** (TST-03):
  - `bridge_status_ok.json` — `/status` mock response shape
  - `bridge_measure_ok.json` — `/measure` MeasurementRecord fields (`cct`, `duv`, `cri`, `r9`, optional `tlci`)
  - `bridge_discover_mock.json` — `/discover` mock-mode response
  - `fixture_db_quote_make.json` — fixture DB edge case (quoted make string)
- **D-49:** Tests compare **key fields and types**, not exact timestamps or uptime (those are dynamic in `/status` and `/measure`).

#### CI workflow (D-50)
- **D-50:** Add **`.github/workflows/ci.yml`** running on push/PR to `claude/lighttune-main` and `cursor/**` branches (TST-04).
- **D-51:** CI jobs: **host-lua** (`lua5.4 tests/run.lua`) and **bridge-pytest** (venv, mock server subprocess or TestClient).
- **D-52:** Install `lua5.4` via apt on `ubuntu-latest`; Python 3.12 for bridge tests.
- **D-53:** No secrets, no Pi hardware, no MA3 runner in Phase 3 CI.

#### Execution target (D-54)
- **D-54:** Product code and CI land on **`claude/lighttune-main`**; GSD artifacts on `cursor/install-gsd-core-342d` per D-15 convention.

### Claude's Discretion
- FastAPI `TestClient` vs subprocess uvicorn — prefer TestClient if lifespan/mock meter works without port binding.
- Whether `requirements-dev.txt` lives at repo root or under `sekonic-bridge/`.
- Exact pytest file naming (`tests/test_bridge_routes.py` vs `sekonic-bridge/tests/`).

### Deferred Ideas (OUT OF SCOPE)
- Plugin `bridge_client` parse tests — Phase 5
- Bridge API key auth tests — Phase 4
- MA3 LuaSocket integration test on console — Phase 7
- `/capture` and `/learn_trigger` HID wizard route tests — optional dev-only, not CI gate
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TST-01 | Host tests run via `lua5.4` against shared modules (126+ color-math assertions preserved) | Split current 133 PASS into `tests/test_*.lua`; `tests/run.lua` sets `package.path`, aggregates PASS/FAIL, `os.exit(1)` on failure; root wrapper preserves README command |
| TST-02 | Bridge route tests via pytest/httpx against mock meter | `server.py` routes at L169–184 (`/status`), L186–200 (`/discover` mock branch), L550–605 (`/measure`); set `server._use_mock_global = True` before ASGI client lifespan; assert HTTP 200 + JSON contract |
| TST-03 | Golden JSON fixtures for bridge responses and fixture DB edge cases | Four files under `tests/fixtures/` per D-48; Lua fixture_db test loads `fixture_db_quote_make.json` for roundtrip; Python tests load bridge goldens for schema assertions with dynamic-field exclusions (D-49) |
| TST-04 | CI workflow runs host Lua tests and bridge pytest on push | New `.github/workflows/ci.yml`; parallel jobs on `ubuntu-latest`; triggers on `claude/lighttune-main` and `cursor/**`; no secrets |
</phase_requirements>

## Validation Architecture

### Test Framework

| Property | Host Lua | Bridge Python |
|----------|----------|---------------|
| **Framework** | Standalone Lua 5.4 harness (`tests/run.lua`) | pytest + httpx (ASGITransport or TestClient) |
| **Module path** | `package.path .. ";./lua/?.lua;./tests/lib/?.lua"` | `sys.path` includes `sekonic-bridge/` for `import server` |
| **Config file** | none | `sekonic-bridge/requirements-dev.txt` (pytest, httpx); runtime `requirements.txt` unchanged for Pi |
| **Quick run command** | `lua5.4 tests/run.lua` | `pytest sekonic-bridge/tests/ -q` |
| **Legacy command** | `lua5.4 test_color_math.lua` (wrapper → same runner) | — |
| **Estimated runtime** | ~5 s | ~10–15 s (MockMeter `measure()` sleeps 1.5 s per call) |
| **Exit behavior** | Non-zero if any FAIL | pytest exit code |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TST-01 | Domain trio loaded via `require` | unit | `lua5.4 tests/run.lua` | ❌ add `tests/run.lua` + split files |
| TST-01 | 133+ assertions preserved | unit | same; expect `133 passed, 0 failed` summary | ✅ baseline in monolithic file |
| TST-01 | Root wrapper delegates | smoke | `lua5.4 test_color_math.lua` | ❌ refactor to thin wrapper |
| TST-02 | `/status` mock shape | integration | pytest `test_status_mock` | ❌ add |
| TST-02 | `/discover` mock short-circuit | integration | pytest `test_discover_mock` | ❌ add |
| TST-02 | `/measure` MeasurementRecord | integration | pytest `test_measure_mock` | ❌ add |
| TST-02 | `/measure` 503 when disconnected | integration | optional pytest with patched meter | ❌ optional |
| TST-03 | Golden fixture files present | static | `test -f tests/fixtures/bridge_status_ok.json` (×4) | ❌ add |
| TST-03 | Quoted make DB roundtrip | unit | Lua `test_fixture_db.lua` loads golden | ❌ add |
| TST-04 | CI host-lua job green | CI | `.github/workflows/ci.yml` job `host-lua` | ❌ add |
| TST-04 | CI bridge-pytest job green | CI | same workflow job `bridge-pytest` | ❌ add |

### Sampling Rate

- **After every test-layout commit:** `lua5.4 tests/run.lua` must report ≥133 PASS, 0 FAIL
- **After bridge test addition:** `pytest sekonic-bridge/tests/ -q` green with mock global set
- **After golden fixture change:** re-run both suites; update fixture `_comment` fields if contract intentionally changes
- **Before Phase 3 sign-off:** CI workflow green on push; README documents `tests/run.lua` as primary command
- **Max feedback latency:** ~30 s local (Lua + pytest); ~2 min CI (apt + pip + MockMeter sleeps)

### Wave 0 Gaps

- [ ] **`tests/` directory tree** — `run.lua`, `test_color_math.lua`, `test_fixture_db.lua`, `test_goals.lua`, `lib/harness.lua` all absent [VERIFIED: glob finds no `tests/`]
- [ ] **Root wrapper** — `test_color_math.lua` still monolithic (~377 lines) with inline harness; must become thin delegate (D-42)
- [ ] **Golden fixtures** — `tests/fixtures/` absent; quoted-make case only inline in test file today (L203–212)
- [ ] **`sekonic-bridge/requirements-dev.txt`** — absent; only runtime pins in `requirements.txt` (fastapi, uvicorn, pyusb)
- [ ] **Bridge pytest suite** — no `sekonic-bridge/tests/` or repo-root `tests/test_bridge_routes.py` [VERIFIED: `.planning/codebase/TESTING.md` notes zero automated Python tests]
- [ ] **`.github/workflows/ci.yml`** — absent [VERIFIED: no `.github/` in workspace]
- [ ] **`TESTING.md` drift** — still documents duplicate-and-drift pattern and base64 tests removed in Phase 2; update during or after Phase 3 execution
- [x] **`lua5.4` on executor host** — available (`lua5.4 test_color_math.lua` → 133 PASS) [VERIFIED: 2026-07-02]
- [ ] **FastAPI/pytest in default VM** — not pre-installed; CI installs via pip (acceptable per D-52)

## Technical Patterns

### Pattern 1: `tests/run.lua` unified host runner

**What:** Single entry sets paths, loads shared harness, runs domain suites, prints aggregate summary, exits non-zero on failure.  
**When:** CI `host-lua` job and local dev gate.  
**Why:** TST-01; eliminates monolithic 377-line root file; preserves README backward compat via wrapper.

```lua
-- tests/run.lua
package.path = package.path .. ";./lua/?.lua;./tests/lib/?.lua"

local harness = require("harness")
local PASS, FAIL = 0, 0

local function run_suite(name, path)
    local p, f = harness.run_file(path)
    PASS = PASS + p
    FAIL = FAIL + f
end

run_suite("color_math",  "tests/test_color_math.lua")
run_suite("fixture_db",  "tests/test_fixture_db.lua")
run_suite("goals",       "tests/test_goals.lua")

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", PASS, FAIL))
print(string.format("========================================"))
if FAIL > 0 then os.exit(1) end
```

**Harness contract (`tests/lib/harness.lua`):** Export `assert_near`, `assert_equal`, `assert_true`, `assert_false`, `section`, and `run_file(path)` that resets per-file counters or returns `(pass, fail)`. Each suite file receives the harness table and **must not** call `os.exit` — only `run.lua` exits.

**Split boundaries** (from current `test_color_math.lua` section map):

| Target file | Sections moved | Approx. assertions |
|-------------|----------------|--------------------|
| `tests/test_color_math.lua` | `cct_to_xy` … `gel_hint` (L83–145) | ~45 |
| `tests/test_fixture_db.lua` | `json_encode_db_record` … `find_best_for_fixture` (L147–341) | ~75 |
| `tests/test_goals.lua` | `goals_met`, `goal_status_str` (L344–366) | ~13 |

Each suite starts with `local color_math = require("color_math")` (or `fixture_db` / `goals`) — same as today, no logic duplication.

**Root wrapper (D-42):**

```lua
-- test_color_math.lua (repo root — backward compat only)
-- Run with: lua5.4 test_color_math.lua
dofile("tests/run.lua")
```

If `dofile` path is fragile when cwd ≠ repo root, use `debug.getinfo(1, "S").source` to resolve script directory — optional polish, not required for CI (always runs from repo root).

### Pattern 2: pytest + httpx vs FastAPI TestClient

**Context requirement:** D-45 specifies **pytest + httpx**. D-50 allows TestClient if mock lifespan works without port binding.

| Approach | Pros | Cons | Phase 3 recommendation |
|----------|------|------|------------------------|
| **`httpx.ASGITransport(app=app)`** | Literal match to D-45; async-native; no TCP port; fast CI | Must set `_use_mock_global` before client enters lifespan | **Preferred** |
| **Starlette `TestClient(app)`** | Simpler sync API; uses httpx internally (Starlette ≥0.27) | Sync wrapper over async routes; less explicit "httpx" in test code | **Acceptable** per D-50 |
| **Subprocess `uvicorn` + httpx TCP client** | Tests full HTTP stack and port binding | Slow; flaky port conflicts; unnecessary for route contract tests | **Avoid** unless ASGI transport fails |

**Mock meter activation:** `server.py` reads module-global `_use_mock_global` in `lifespan` (L149–151) — default `False`; CLI `--mock` sets it in `main()` only. Tests **must** set the global before constructing the ASGI client:

```python
# sekonic-bridge/tests/conftest.py
import pytest
import httpx
from httpx import ASGITransport

import server

@pytest.fixture
def mock_app():
    server._use_mock_global = True
    return server.app

@pytest.fixture
async def client(mock_app):
    transport = ASGITransport(app=mock_app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac
```

Use `pytest-asyncio` mode `auto` or `@pytest.mark.anyio` for async tests. Alternative sync fixture with `TestClient(server.app)` after `server._use_mock_global = True`.

**Route assertions (D-47):**

| Route | Method | Mock behavior (source) | Key assertions |
|-------|--------|------------------------|----------------|
| `/status` | GET | L169–183; flags true when mock | `status=="ok"`, `meter=="C-7000"`, `connected is True`, `version` present; **ignore** `uptime_s` |
| `/discover` | GET | L192–200 short-circuit | Matches golden `bridge_discover_mock.json` keys |
| `/measure` | POST | L574–589 via `MockMeter.measure()` | Keys `cct`, `duv`, `cri`, `r9`, `tlci`; types int/float; ranges from `_CCT_STEPS[0]` ± jitter; **ignore** `timestamp` |

**Out of scope for CI:** `/capture` (L321+), `/learn_trigger` (L469+) — setup wizard endpoints; smoke optional in dev only (CONTEXT deferred).

**Dev dependencies layout:** Prefer `sekonic-bridge/requirements-dev.txt`:

```text
pytest>=8.0
pytest-asyncio>=0.23
httpx>=0.27
-r requirements.txt
```

Pi production image installs only `requirements.txt` (D-45).

### Pattern 3: Golden fixture schema

Golden files document the **contract** between bridge and plugin (Phase 5 parser) and fixture DB encoder. Tests load JSON and assert structure — not byte-identical responses.

#### `tests/fixtures/bridge_status_ok.json`

Schema reference for mock `/status` (dynamic fields excluded at compare time):

```json
{
  "_schema": "bridge_status_v1",
  "_dynamic_fields": ["uptime_s", "last_error"],
  "status": "ok",
  "meter": "C-7000",
  "connected": true,
  "version": "0.5.0-replan",
  "device_configured": true,
  "protocol_captured": true,
  "trigger_discovered": true
}
```

Compare: all keys except `_schema`, `_dynamic_fields`, and listed dynamic fields; assert types (`connected` bool, `uptime_s` int when present).

#### `tests/fixtures/bridge_measure_ok.json`

MeasurementRecord contract (plugin regex targets these keys):

```json
{
  "_schema": "measurement_record_v1",
  "_dynamic_fields": ["timestamp"],
  "_required_keys": ["cct", "duv", "cri", "r9"],
  "_optional_keys": ["tlci"],
  "_types": {
    "cct": "integer",
    "duv": "number",
    "cri": "integer",
    "r9": "integer",
    "tlci": "integer"
  },
  "_ranges_first_mock_call": {
    "cct": [4075, 4125],
    "duv": [0.0079, 0.0091],
    "cri": [70, 74],
    "r9": [38, 46],
    "tlci": [65, 71]
  }
}
```

First `/measure` in a fresh process uses MockMeter call #1 centers (`meter_mock.py` L39–43) plus jitter (L83–87). Tests assert keys/types and range membership — not exact values (D-49).

#### `tests/fixtures/bridge_discover_mock.json`

Exact mock response (no dynamic fields):

```json
{
  "configured": true,
  "manufacturer": "Sekonic",
  "product": "C-7000 (mock)",
  "vendor_id": "0x0000",
  "product_id": "0x0000",
  "devices": []
}
```

[VERIFIED: matches `server.py` L193–200]

#### `tests/fixtures/fixture_db_quote_make.json`

Fixture DB edge case — quoted make string (ARCH-02 / D-48):

```json
{
  "_schema": "fixture_db_record_v1",
  "record": {
    "make": "Acme \"Pro\" 600",
    "model": "X",
    "kelvin": 5600,
    "date": "2026-01-01",
    "contributor": "t",
    "cct": 5580,
    "duv": 0.003,
    "cri": 90,
    "r9": 80
  },
  "expect": {
    "parse_count": 1,
    "skipped": 0,
    "make_roundtrip": "Acme \"Pro\" 600"
  }
}
```

Lua test: `json_encode_db_array({record})` → parse → assert `expect`. Can replace inline literal at current L203–212.

**Note:** `_schema` and `_dynamic_fields` keys are test-metadata; strip before comparing to live HTTP responses.

### Pattern 4: GitHub Actions job layout

**File:** `.github/workflows/ci.yml`

**Triggers (D-50):**

```yaml
on:
  push:
    branches: [claude/lighttune-main, cursor/**]
  pull_request:
    branches: [claude/lighttune-main]
```

**Jobs (D-51, parallel):**

```yaml
jobs:
  host-lua:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Lua 5.4
        run: sudo apt-get update && sudo apt-get install -y lua5.4
      - name: Run host tests
        run: lua5.4 tests/run.lua

  bridge-pytest:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: sekonic-bridge
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements-dev.txt
      - name: Run bridge tests
        run: pytest tests/ -q
```

**Design notes:**

- **No matrix** — single OS/Python/Lua version matches STACK.md dev/CI standard.
- **No secrets** (D-53) — mock meter only; no `bridge_api_key` until Phase 4.
- **No artifact upload** — pass/fail exit codes only.
- **Working directory:** host-lua runs from repo root; bridge-pytest from `sekonic-bridge/` so `import server` resolves.
- **Optional follow-up:** add `workflow_dispatch` for manual runs; not required for TST-04.

### Pattern 5: Module inventory under test

| Module | Path | Host-testable API | Current coverage |
|--------|------|-------------------|------------------|
| Color math | `lua/color_math.lua` | `cct_to_xy`, `xy_to_uvp`, `apply_duv_correction`, `rate_quality`, `gel_hint`, … | 133 PASS (partial) |
| Fixture DB | `lua/fixture_db.lua` | `json_encode_db_array`, `json_parse_db_array`, `recompute_best_flags`, `append_fixture_record`, … | 133 PASS (partial) |
| Goals | `lua/goals.lua` | `goals_met`, `goal_status_str`, `QUALITY`, `GOAL_*` | 133 PASS (partial) |
| Plugin entry | `lua/SekonicCalibrator.lua` | MA3-coupled — **not** Phase 3 host tests | Phase 7 UAT |
| Bridge server | `sekonic-bridge/server.py` | `/status`, `/measure`, `/discover` | None automated |
| Mock meter | `sekonic-bridge/meter_mock.py` | `connect`, `measure` progression | None automated |

## Bridge Route Reference (implementation anchors)

| Endpoint | Handler | Mock branch | MeasurementRecord keys |
|----------|---------|-------------|------------------------|
| `GET /status` | `status()` L169 | Config flags forced true L180–182 | N/A (health JSON) |
| `GET /discover` | `discover()` L186 | Returns fixed mock dict L193–200 | N/A |
| `POST /measure` | `measure()` L550 | `MockMeter.measure()` via executor L578–589 | `cct`, `duv`, `cri`, `r9`, `tlci?`, `timestamp` |

MockMeter progression table (`meter_mock.py` L39–43) enables optional test that second `/measure` returns higher CCT than first — useful smoke, not required for TST-02 minimum.

## Environment Availability

| Dependency | Required By | Available (workspace) | CI install | Fallback |
|------------|-------------|----------------------|------------|----------|
| lua5.4 | TST-01 | ✓ | apt | — |
| Python 3.12 | TST-02 | ✓ (3.12.3) | setup-python | — |
| fastapi/uvicorn | TST-02 | ✗ (not in default venv) | pip via requirements-dev | — |
| pytest/httpx | TST-02 | ✗ | pip via requirements-dev | — |
| pyusb | TST-02 runtime import | ✗ optional for mock routes | pip via requirements.txt | Mock `/discover` skips USB |
| GrandMA3 / Pi / C-7000 | — | ✗ | not in CI (D-53) | Phase 7 UAT |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Test split drops assertions | False green CI | Count PASS before/after split; gate on ≥133 |
| `_use_mock_global` not set before lifespan | Real USB code path in tests | conftest sets global; assert `connected` true without hardware |
| MockMeter 1.5 s sleep slows CI | Longer bridge job | Accept ~10 s; limit `/measure` calls per test; no subprocess uvicorn |
| Golden fixtures drift from server | Brittle CI | Anchor to `server.py` mock branches; `_schema` version bumps |
| `bridge.log` written during tests | Side effect in sekonic-bridge/ | chdir to tmp or monkeypatch log handler — optional hygiene |

## Primary Sources

### Verified (HIGH confidence)
- `/workspace/.planning/phases/03-shared-test-strategy-ci/03-CONTEXT.md` — D-40–D-54 locked decisions
- `/workspace/.planning/ROADMAP.md` — Phase 3 success criteria, TST-01–04
- `/workspace/.planning/REQUIREMENTS.md` — TST requirement definitions
- `/workspace/test_color_math.lua` — 133 PASS baseline, 17 sections, module requires
- `/workspace/lua/color_math.lua`, `fixture_db.lua`, `goals.lua` — domain trio exports
- `/workspace/sekonic-bridge/server.py` — route handlers, mock branches, lifespan
- `/workspace/sekonic-bridge/meter_mock.py` — progression tables, jitter, return dict shape
- `/workspace/.planning/phases/02-plugin-hardening-test-seams/02-03-SUMMARY.md` — Phase 2 gate 133 PASS

### Secondary (MEDIUM confidence)
- `.planning/research/STACK.md` — pytest + httpx recommendation, CI layout
- `.planning/codebase/TESTING.md` — brownfield gaps (pre–Phase 3; needs refresh after execution)
- `.planning/phases/02-plugin-hardening-test-seams/02-RESEARCH.md` — Validation Architecture template

## Metadata

**Confidence breakdown:**
- Host test split inventory: **HIGH** — section map and assertion count verified by execution
- Bridge mock test approach: **HIGH** — mock branches explicit in source; no USB in CI
- Golden fixture schema: **HIGH** — aligned to live mock responses and plugin MeasurementRecord contract
- CI workflow layout: **HIGH** — standard ubuntu-latest + apt + pip pattern

**Research date:** 2026-07-02  
**Valid until:** 2026-08-02

## RESEARCH COMPLETE
