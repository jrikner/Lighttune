# Phase 3: Shared Test Strategy & CI - Context

**Gathered:** 2026-07-02
**Status:** Ready for planning
**Source:** Inferred from ROADMAP Phase 3, Phase 2 execution outcomes, and REQUIREMENTS TST-01–04 (no `/gsd-discuss-phase 3` session)

<domain>
## Phase Boundary

Add a **unified host test runner**, **golden JSON fixtures**, **bridge route tests** (pytest/httpx against mock meter), and a **GitHub Actions CI workflow** that runs on push. Builds on Phase 2 domain modules (`color_math`, `fixture_db`, `goals`) and existing `sekonic-bridge/` from Phase 1.

**In scope:** TST-01, TST-02, TST-03, TST-04  
**Out of scope:** Bridge thinning (Phase 4), plugin HTTP client tests (Phase 5), MA3 console tests (Phase 7), `/capture` and `/learn_trigger` route CI (setup-only endpoints; smoke optional only)

</domain>

<decisions>
## Implementation Decisions

### Host test layout (D-40)
- **D-40:** Create `tests/` directory with **`tests/run.lua`** as the single host entry point (TST-01).
- **D-41:** Split domain tests into `tests/test_color_math.lua`, `tests/test_fixture_db.lua`, `tests/test_goals.lua` — each `require`s shared modules from `lua/`.
- **D-42:** Keep **`test_color_math.lua` at repo root** as a thin wrapper that invokes `tests/run.lua` or delegates to it (backward compat for README/docs); root file must not duplicate logic (D-34 carry-forward).

### Assertion baseline (D-43)
- **D-43:** CI must preserve **133+ PASS** (current post–Phase 2 count); ROADMAP "126+" is minimum floor, not regression target.
- **D-44:** `tests/run.lua` sets `package.path` to `./lua/?.lua` and exits non-zero on any FAIL.

### Bridge test stack (D-45)
- **D-45:** Use **pytest + httpx** for bridge route tests (TST-02); add `pytest`, `httpx` to bridge dev dependencies (separate from Pi runtime `requirements.txt` or as `sekonic-bridge/requirements-dev.txt`).
- **D-46:** Bridge tests start server with **`--mock`** flag; no USB hardware in CI.
- **D-47:** Test **`GET /status`**, **`POST /measure`**, **`GET /discover`** only — the three routes in ROADMAP Phase 3 success criteria. Do not require `/capture` or `/learn_trigger` to pass CI.

### Golden fixtures (D-48)
- **D-48:** Store golden JSON under **`tests/fixtures/`** (TST-03):
  - `bridge_status_ok.json` — `/status` mock response shape
  - `bridge_measure_ok.json` — `/measure` MeasurementRecord fields (`cct`, `duv`, `cri`, `r9`, optional `tlci`)
  - `bridge_discover_mock.json` — `/discover` mock-mode response
  - `fixture_db_quote_make.json` — fixture DB edge case (quoted make string)
- **D-49:** Tests compare **key fields and types**, not exact timestamps or uptime (those are dynamic in `/status` and `/measure`).

### CI workflow (D-50)
- **D-50:** Add **`.github/workflows/ci.yml`** running on push/PR to `claude/lighttune-main` and `cursor/**` branches (TST-04).
- **D-51:** CI jobs: **host-lua** (`lua5.4 tests/run.lua`) and **bridge-pytest** (venv, mock server subprocess or TestClient).
- **D-52:** Install `lua5.4` via apt on `ubuntu-latest`; Python 3.12 for bridge tests.
- **D-53:** No secrets, no Pi hardware, no MA3 runner in Phase 3 CI.

### Execution target (D-54)
- **D-54:** Product code and CI land on **`claude/lighttune-main`**; GSD artifacts on `cursor/install-gsd-core-342d` per D-15 convention.

### Claude's Discretion
- FastAPI `TestClient` vs subprocess uvicorn — prefer TestClient if lifespan/mock meter works without port binding.
- Whether `requirements-dev.txt` lives at repo root or under `sekonic-bridge/`.
- Exact pytest file naming (`tests/test_bridge_routes.py` vs `sekonic-bridge/tests/`).

</decisions>

<canonical_refs>
## Canonical References

### Requirements & roadmap
- `.planning/ROADMAP.md` — Phase 3 goal, success criteria, TST-01–04
- `.planning/REQUIREMENTS.md` — TST definitions
- `.planning/phases/02-plugin-hardening-test-seams/02-03-SUMMARY.md` — 133 tests, domain trio on main

### Codebase
- `lua/color_math.lua`, `lua/fixture_db.lua`, `lua/goals.lua` — shared modules under test
- `test_color_math.lua` — current monolithic host runner (to split)
- `sekonic-bridge/server.py` — FastAPI routes `/status`, `/measure`, `/discover`
- `sekonic-bridge/meter_mock.py` — mock backend for CI
- `sekonic-bridge/requirements.txt` — runtime deps (fastapi, uvicorn, pyusb)

### Research
- `.planning/research/STACK.md` — lua5.4 host + Python venv testing strategy
- `.planning/codebase/TESTING.md` — brownfield test notes

</canonical_refs>

<deferred>
## Deferred Ideas

- Plugin bridge_client parse tests — Phase 5
- Bridge API key auth tests — Phase 4
- MA3 LuaSocket integration test on console — Phase 7
- `/capture` and `/learn_trigger` HID wizard route tests — optional dev-only, not CI gate

</deferred>

---

*Phase: 3-Shared Test Strategy & CI*
*Context gathered: 2026-07-02*
