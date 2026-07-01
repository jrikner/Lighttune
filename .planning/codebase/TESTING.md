# Testing Patterns

**Analysis Date:** 2026-07-01

## Test Framework

**Runner:**
- Standalone Lua 5.4 interpreter (no Busted, LuaUnit, or teast detected)
- Single test script: `test_color_math.lua` at repository root
- Config: none (no `busted`, `.luacov`, or CI workflow)

**Assertion Library:**
- Custom inline helpers defined at top of `test_color_math.lua`:
  - `assert_near(label, got, expected, tolerance)` — default tolerance `0.0005`
  - `assert_equal(label, got, expected)` — strict equality (`==`)
  - `assert_true(label, condition)`
  - `assert_false(label, condition)`
  - `section(name)` — prints `[section name]` banner

**Run Commands:**
```bash
lua5.4 test_color_math.lua              # Run all tests (documented in README.md)
lua test_color_math.lua                 # Alternative if lua5.4 not on PATH
```

**Exit behavior:**
- Prints pass/fail per assertion with `PASS` / `FAIL` prefix
- Summary: `Results: N passed, M failed`
- `os.exit(1)` when `FAIL > 0`; exit 0 when all pass
- README documents expected outcome: **126 passed, 0 failed**

## Test File Organization

**Location:**
- Tests live at repo root as `test_color_math.lua`, **not** co-located under `lua/`
- No `tests/` directory, no `*_spec.lua` naming

**Naming:**
- `test_<area>.lua` pattern (currently only color math + DB helpers)

**Structure:**
```
/workspace/
├── lua/
│   └── SekonicCalibrator.lua    # Production plugin (not required by tests)
├── test_color_math.lua          # Test runner + duplicated pure logic + assertions
├── data/
│   └── config.json.example      # Not exercised by tests
└── plugin.xml                   # Not exercised by tests
```

## Test Structure

**Suite Organization:**
- Tests grouped by `section("...")` calls matching functional areas
- Each section contains `do ... end` blocks or bare assertion lines
- Pure function implementations are **copied inline** from `lua/SekonicCalibrator.lua` Sections 2 and 2b (lines 57–301 in test file mirror production logic)

**Patterns:**
- **Setup:** Inline table literals per test; no shared `before_each`
- **Teardown:** None; tests mutate local `records` arrays only within `do` blocks
- **Assertion:** Every check increments global `PASS` or `FAIL` counters and prints a labeled line

**Example pattern from codebase:**
```lua
section("cct_to_xy – known reference values (Kang et al.)")
do
    local x, y = cct_to_xy(3200)
    assert_near("3200K x", x, 0.4232, 0.005)
    assert_near("3200K y", y, 0.3974, 0.005)
end
```

**Section coverage in `test_color_math.lua`:**

| Section | What is tested |
|---------|----------------|
| `cct_to_xy – known reference values` | Kang et al. reference xy at 3200K, 5600K, 6500K, 4000K boundary |
| `xy_to_uvp / uvp_to_xy – roundtrip` | Chromaticity round-trip at three xy pairs |
| `apply_duv_correction` | Identity when measured=target; green shift direction |
| `xy_to_rgb / rgb_to_hsb` | D65 white, primary hues, white saturation |
| `rate_quality – CRI/R9/TLCI/Duv boundaries` | Threshold boundary strings Excellent/Good/Acceptable/Poor |
| `gel_hint – direction and amount` | Nil below threshold; Minus/Plus Green amounts |
| `base64_encode – RFC 4648 vectors` | Known RFC test vectors |
| `base64_decode – roundtrip` | Decode vectors + binary round-trip |
| `json_encode_db_record / json_parse_db_array` | Empty array, full record, nil tlci, negative Duv |
| `best_* flags not written when false/nil` | Encoder omits false flags |
| `recompute_best_flags – correctness` | Single record, competing records, independent groups, negative Duv |
| `append_fixture_record` | Append-only semantics and flag recomputation |
| `sort_fixture_records – ordering` | make → model → kelvin → date |
| `find_best_for_fixture` | Entry count, best pointers, nil for unknown fixture |

## Mocking

**Framework:** None — no mock library.

**Patterns:**
- **Duplication instead of `require`:** Test file re-implements pure functions rather than loading `lua/SekonicCalibrator.lua` (which would pull in GrandMA3 globals and `return main`)
- **No MA3 API tests:** `MessageBox`, `DataPool`, `Cmd`, `SetColor`, file I/O paths, and `main()` workflow are untested in automation
- **Deterministic dates in tests:** `append_fixture_record` copy uses `date or "2026-01-01"` instead of production's `os.date("%Y-%m-%d")` for stable assertions

**What to Mock:**
- Not applicable today — tests are pure-function only
- If adding MA3 integration tests in future, would need stub globals (`MessageBox`, `DataPool`, `Cmd`, `SetColor`, `GetPath`, `io.open`)

**What NOT to Mock:**
- Color math and JSON DB helpers — tested directly against duplicated implementations
- When changing Section 2/2b in `lua/SekonicCalibrator.lua`, **must sync** the inline copy in `test_color_math.lua` (no automated drift check)

## Fixtures and Factories

**Test Data:**
- Inline table literals; no shared factory module

**Example record fixture:**
```lua
local rec = {
    make = "Aputure", model = "600X Pro", kelvin = 5600,
    date = "2026-03-13", contributor = "jrikner",
    cct = 5572, duv = 0.003, cri = 95, r9 = 88, tlci = 91,
    best_cri = true, best_r9 = true, best_tlci = true, best_duv = true
}
```

**Location:**
- All fixtures defined inside `test_color_math.lua` near the tests that use them
- Production data files (`data/fixture_log.json`) gitignored — not used as golden files in tests

## Coverage

**Requirements:** None enforced; no coverage tool configured

**View Coverage:**
- Not available — add luacov or similar if coverage becomes a requirement

**De facto coverage map:**

| Area | Automated | Notes |
|------|-----------|-------|
| Color math (Section 2) | Yes | High assertion density |
| JSON DB helpers (Section 2b) | Yes | Encode/parse/flags/sort/find |
| Base64 helpers | Yes | RFC vectors + round-trip |
| UI helpers (Section 3) | No | MessageBox-driven |
| GDTF/patch capabilities (Section 3b) | No | Requires DataPool |
| Fixture application (Section 4) | No | Requires Cmd/SetColor |
| Data logging / config (Section 5) | No | Requires io + GetPath |
| `main()` workflow (Section 6) | No | End-to-end manual on console |

## Test Types

**Unit Tests:**
- Scope: pure functions and DB logic isolated from GrandMA3
- Style: label every assertion; floating-point via `assert_near` with explicit tolerance
- Boundary testing emphasized for `rate_quality`, `rate_duv`, `gel_hint` thresholds

**Integration Tests:**
- Not present

**E2E Tests:**
- Not present — calibration workflow validated manually on GrandMA3 console with Sekonic hardware

## Common Patterns

**Async Testing:**
- Not applicable (synchronous script)

**Error Testing:**
- Indirect only — e.g. empty parse of `[]`, nil return from `find_best_for_fixture` for unknown models
- No tests for `pcall` failure paths or MessageBox cancel flows

**Floating-point assertions:**
```lua
assert_near("3200K x", x, 0.4232, 0.005)   -- default tol 0.0005 when omitted
assert_near("duv", parsed[1].duv, 0.003, 0.0001)
```

**String partial match for gel hints:**
```lua
local h = gel_hint(0.004)
assert_equal("Duv +0.004=1/8 Minus", h and h:sub(1, 11) or nil, "1/8 Minus G")
```

**Directional / inequality checks:**
```lua
if vpc < vp0 then
    print("  PASS  green correction shifts v' toward magenta"); PASS = PASS + 1
else
    print("  FAIL  green correction direction wrong"); FAIL = FAIL + 1
end
```

## Adding New Tests

**When changing pure logic in `lua/SekonicCalibrator.lua`:**
1. Mirror the change in the inline copy inside `test_color_math.lua` (Sections marked `-- Inline copies`)
2. Add a `section("...")` block with assertions
3. Run `lua5.4 test_color_math.lua` and update README expected pass count if assertions added

**When adding UI or MA3 integration code:**
- No existing pattern — would require either global stubs in a new test file or manual UAT on console
- Prefer keeping testable logic in Section 2/2b per production file conventions

**CI:**
- No `.github/workflows` detected — tests are local developer/console checks only
- Recommended CI step if added: `lua5.4 test_color_math.lua` on push

---

*Testing analysis: 2026-07-01*
