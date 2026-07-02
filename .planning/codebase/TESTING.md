# Testing Patterns

**Analysis Date:** 2026-07-01

**Branch scope:** Host-side Lua tests exist on all branches with `test_color_math.lua`. Bridge testing (`sekonic-bridge/meter_mock.py`, `--mock` mode) exists only on `origin/claude/sekonic-remote-api-research-HdMTl` and related Sekonic branches — **not** on `origin/claude/lighttune-main`.

---

## Test Framework

### Lua (host-side)

**Runner:**
- Standalone **Lua 5.4** interpreter (no Busted, LuaUnit, or teast)
- Single test script: `test_color_math.lua` at repository root
- No CI workflow or test config files detected

**Assertion library:**
- Custom inline helpers at top of `test_color_math.lua`:
  - `assert_near(label, got, expected, tolerance)` — default tolerance `0.0005`
  - `assert_equal(label, got, expected)` — strict `==`
  - `assert_true(label, condition)` / `assert_false(label, condition)`
  - `section(name)` — prints `[section name]` banner

**Run commands:**
```bash
lua5.4 test_color_math.lua              # Documented in README.md
lua test_color_math.lua                 # If lua5.4 not on PATH
```

**Exit behavior:**
- Per-assertion `PASS` / `FAIL` lines
- Summary: `Results: N passed, M failed`
- `os.exit(1)` when `FAIL > 0`
- README expected outcome: **126 passed, 0 failed**

### Python (sekonic-bridge — manual / dev only)

**Runner:** None automated — no pytest, unittest suite, or tox config.

**Dev backend:** `meter_mock.py` + `python3 server.py --mock` (documented in `sekonic-bridge/README.md`).

**Run commands:**
```bash
cd sekonic-bridge
pip install -r requirements.txt
python3 server.py --mock --host 0.0.0.0 --port 8765

# Manual API checks (separate terminal)
curl -s http://localhost:8765/status | jq .
curl -s -X POST http://localhost:8765/measure | jq .
```

---

## Test File Organization

### Lua

**Location:** Repo root — `test_color_math.lua`, **not** under `lua/` or `tests/`

**Naming:** `test_<area>.lua` (only color math + DB helpers today)

**Structure:**
```
/workspace/                          # lighttune-main + shared
├── lua/SekonicCalibrator.lua        # v0.4 or v0.5 by branch; NOT loaded by tests
├── test_color_math.lua              # Duplicated Section 2/2b + assertions
├── data/config.json.example         # Not exercised by tests
└── plugin.xml                       # Not exercised by tests

sekonic-bridge/                      # sekonic branch only
├── server.py
├── meter_mock.py                    # Dev/test double for C7000HID
├── meter_c7000_hid.py               # Hardware driver (untested in CI)
├── discover_device.py               # CLI utility (untested)
└── requirements.txt
```

---

## test_color_math.lua Patterns

### Design: duplicate, don't require

Tests **re-implement** Sections 2 and 2b inline (lines 57–301) rather than `require("lua/SekonicCalibrator.lua")` because the plugin file ends with `return main` and references GrandMA3 globals.

**Header comment:**
```lua
-- Standalone Lua 5.4 unit tests for SekonicCalibrator color math functions.
-- Run with: lua test_color_math.lua
-- Tests exercise pure color math logic and DB helpers independently of MA3 API.
```

### Assertion helpers

| Helper | Use when |
|--------|----------|
| `assert_near` | Floats (CCT xy, Duv, chromaticity) — pass explicit tolerance for boundaries |
| `assert_equal` | Strings, integers, nil |
| `assert_true` / `assert_false` | Boolean flags (`best_cri`, presence in JSON) |

### Suite layout

- `section("...")` banners group related cases
- `do ... end` blocks for scoped locals
- Global `PASS` / `FAIL` counters incremented per assertion
- One directional check uses manual `print` + counter increment (green correction shifts v′)

### Section coverage

| Section | What is tested |
|---------|----------------|
| `cct_to_xy – known reference values` | Kang et al. xy at 3200K, 5600K, 6500K, 4000K boundary |
| `xy_to_uvp / uvp_to_xy – roundtrip` | Round-trip at three xy pairs |
| `apply_duv_correction` | Identity; green/magenta direction |
| `xy_to_rgb / rgb_to_hsb` | D65, primaries, white |
| `rate_quality – CRI/R9/TLCI/Duv boundaries` | Excellent/Good/Acceptable/Poor edges |
| `gel_hint – direction and amount` | Threshold steps; Minus/Plus Green |
| `base64_encode / base64_decode` | RFC 4648 vectors + binary round-trip |
| `json_encode_db_record / json_parse_db_array` | Empty array, full record, nil tlci, negative Duv |
| `best_* flags not written when false/nil` | Encoder omits false flags |
| `recompute_best_flags` | Competition, groups, negative Duv wins |
| `append_fixture_record` | Append-only; flag recomputation |
| `sort_fixture_records` | make → model → kelvin → date |
| `find_best_for_fixture` | Counts, best pointers, nil for unknown |

### Stability conventions

- `append_fixture_record` copy uses `date or "2026-01-01"` instead of `os.date("%Y-%m-%d")` for deterministic assertions
- Gel hint tests use `h:sub(1, N)` partial string match on formatted hints

### Sync requirement

When editing Section 2 or 2b in `lua/SekonicCalibrator.lua`, **manually mirror** changes in the inline copy inside `test_color_math.lua`. No drift detection exists. v0.5 Section 2c (bridge) is **not** mirrored in tests.

---

## meter_mock.py — Bridge Dev Testing

**Path:** `sekonic-bridge/meter_mock.py` (sekonic branch)

**Role:** Drop-in replacement for `C7000HID` when `server.py --mock` is passed. Implements the same implicit meter interface as real hardware.

### Interface contract (must match `C7000HID`)

```python
class MockMeter:
    def connect(self) -> bool: ...
    def is_connected(self) -> bool: ...
    def disconnect(self): ...
    def measure(self) -> dict:  # {"cct", "duv", "cri", "r9", "tlci"}
```

### Simulated calibration progression

Mock returns **correlated** values that improve over successive `measure()` calls (simulates uncorrected LED PAR converging toward goal):

| Call # | Approx CCT | Approx Duv | CRI | R9 | TLCI |
|--------|------------|------------|-----|-----|------|
| 1 | 4100 K | +0.0085 | 72 | 42 | 68 |
| 2 | 4920 K | +0.0042 | 81 | 58 | 77 |
| 3 | 5480 K | +0.0015 | 88 | 72 | 86 |
| 4 | 5590 K | +0.0003 | 92 | 83 | 90 |
| 5+ | 5605 K | +0.0001 | 94 | 85 | 92 |

- Index capped at last step; jitter added per call (CCT ±25 K, Duv ±0.0006, etc.)
- `time.sleep(1.5)` simulates measurement cycle; `connect()` sleeps 0.1 s
- `_call_count` resets when a new `MockMeter()` is instantiated (each server restart)

### Mock mode server behavior

From `server.py`:
- `/status` reports `connected: true`, all config flags true when `--mock`
- `/discover`, `/learn_trigger` short-circuit with success responses
- `/measure` delegates to `MockMeter.measure()` inside executor + 35 s timeout

### End-to-end dev workflow

1. Start mock bridge on dev machine
2. Set `bridge_ip` / `bridge_port` in plugin `config.json` to dev machine IP
3. Run GrandMA3 plugin v0.5 — exercise Bridge Status, remote measure, auto-loop
4. Repeated POST `/measure` calls walk through progression table — useful for validating Lua `goals_met()` and auto-loop without C-7000 hardware

**Documented in:** `sekonic-bridge/README.md` § "Running in Mock Mode (development/testing)"

---

## Mocking

### Lua tests

- **No mock library** — duplication pattern only
- **No MA3 globals stubbed** — `MessageBox`, `DataPool`, `Cmd`, `SetColor`, `socket` untested

### Python bridge

- **`MockMeter`** is the only formal test double
- **`C7000HID`** requires USB hardware + pyusb; no recorded fixtures or VCR-style tests
- **`discover_device.py`** — manual CLI; no automated assertions

**What NOT to mock in future Python tests:** Protocol byte parsing in `_parse()` — prefer golden 2380-byte fixture files over mocking struct.unpack.

---

## Fixtures and Factories

**Lua:** Inline table literals in `test_color_math.lua`; no shared factory module.

**Example record:**
```lua
local rec = {
    make = "Aputure", model = "600X Pro", kelvin = 5600,
    date = "2026-03-13", contributor = "jrikner",
    cct = 5572, duv = 0.003, cri = 95, r9 = 88, tlci = 91,
    best_cri = true, best_r9 = true, best_tlci = true, best_duv = true
}
```

**Python:** No test fixtures checked in. Runtime configs (`device_config.json`, `bridge.log`) are local artifacts.

---

## Coverage

**Requirements:** None enforced; no luacov, pytest-cov, or CI.

### De facto coverage map

| Area | Branch | Automated | Notes |
|------|--------|-----------|-------|
| Color math (Lua §2) | all | Yes | `test_color_math.lua` |
| JSON DB helpers (Lua §2b) | all | Yes | High assertion density |
| Base64 (Lua §2b) | all | Yes | RFC vectors |
| Bridge HTTP client (Lua §2c) | v0.5 | **No** | `_http_request`, regex JSON parse |
| `goals_met` / auto-loop (Lua §2c/§6) | v0.5 | **No** | Console or mock-bridge manual |
| UI / MA3 API (Lua §3–6) | all | **No** | MessageBox-driven |
| `meter_mock.py` progression | sekonic | **No** | Manual curl / plugin |
| `server.py` routes | sekonic | **No** | Manual curl |
| `meter_c7000_hid.py` USB protocol | sekonic | **No** | Hardware-only |
| `discover_device.py` | sekonic | **No** | CLI manual |
| Config loading (`bridge_ip`) | v0.5 | **No** | Regex parser untested |

---

## Test Types

**Unit tests (Lua):** Pure functions + DB logic — synchronous script, label every assertion.

**Integration tests:** Not present (no harness loading plugin + stub globals).

**E2E tests:** Not present — calibration validated manually on GrandMA3 with Sekonic hardware or mock bridge.

**Manual bridge QA checklist (documented, not automated):**
1. `python3 server.py --mock` → `GET /status` returns 200
2. Repeated `POST /measure` → values trend toward table above
3. Plugin Bridge Status wizard → discover/capture/learn_trigger (mock returns success)
4. Real Pi + C-7000: same endpoints with hardware backend

---

## Common Patterns

**Floating-point (Lua):**
```lua
assert_near("3200K x", x, 0.4232, 0.005)
assert_near("duv", parsed[1].duv, 0.003, 0.0001)
```

**String partial match (Lua gel hints):**
```lua
local h = gel_hint(0.004)
assert_equal("Duv +0.004=1/8 Minus", h and h:sub(1, 11) or nil, "1/8 Minus G")
```

**Error / nil paths (Lua):** Only indirect — empty `[]`, `find_best_for_fixture` nil; no tests for bridge HTTP failures.

**Async (Python):** Routes tested manually; no `pytest-asyncio` patterns in repo.

---

## Gaps and Recommended Additions

### Critical gaps (no Python tests yet)

1. **`meter_mock.py`** — No assertions that progression indices, jitter clamps, or return dict keys match contract
2. **`server.py`** — No tests for `/measure` lock, timeout, error JSON shape, or `/status` flag logic
3. **`meter_c7000_hid._parse()`** — No golden-file test with sample 2380-byte NR payload
4. **Lua §2c** — `_http_request`, `bridge_fetch_measurement`, `goals_met` untested on host (could extract pure regex/range checks to duplicated test block)
5. **`load_config()` bridge fields** — Regex parsing for `bridge_ip` / `bridge_port` untested
6. **CI** — No `.github/workflows`; only documented local `lua5.4 test_color_math.lua`

### Lower priority

- `discover_device.py` USB scan (needs mock usb.core or hardware)
- `/learn_trigger` candidate iteration (slow; integration only)
- v0.4 vs v0.5 behavioral diff tests (branch-specific; mock bridge is v0.5 only)

### Adding new Lua tests

1. Mirror Section 2/2b changes in `test_color_math.lua` inline copy
2. Add `section("...")` + assertions
3. Run `lua5.4 test_color_math.lua`; update README pass count if assertions added
4. For v0.5 bridge pure logic (`goals_met`), prefer new inline functions in test file over requiring plugin

### Adding new Python tests (recommended layout)

```
sekonic-bridge/
├── tests/
│   test_meter_mock.py      # progression, clamps, connect/measure contract
│   test_server_mock.py     # TestClient + --mock lifespan
│   fixtures/
│       nr_response_2380.bin
├── pytest.ini              # optional
```

Use `httpx.AsyncClient` + FastAPI `TestClient` with `_use_mock_global = True` or pytest fixture patching `_load_meter`.

---

*Testing analysis: 2026-07-01*
