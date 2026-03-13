-- test_color_math.lua
-- Standalone Lua 5.4 unit tests for SekonicCalibrator color math functions.
-- Run with: lua test_color_math.lua
--
-- These tests exercise the pure color math logic independently of the MA3 API.

local PASS = 0
local FAIL = 0

local function assert_near(label, got, expected, tolerance)
    tolerance = tolerance or 0.0005
    if math.abs(got - expected) <= tolerance then
        print(string.format("  PASS  %s  (got %.6f, expected %.6f)", label, got, expected))
        PASS = PASS + 1
    else
        print(string.format("  FAIL  %s  (got %.6f, expected %.6f, diff %.6f)",
            label, got, expected, math.abs(got - expected)))
        FAIL = FAIL + 1
    end
end

local function assert_equal(label, got, expected)
    if got == expected then
        print(string.format("  PASS  %s  (got '%s')", label, tostring(got)))
        PASS = PASS + 1
    else
        print(string.format("  FAIL  %s  (got '%s', expected '%s')", label, tostring(got), tostring(expected)))
        FAIL = FAIL + 1
    end
end

local function section(name)
    print("\n[" .. name .. "]")
end

--------------------------------------------------------------------------------
-- Inline copies of color math (mirrors SekonicCalibrator.lua Section 2)
--------------------------------------------------------------------------------

local CCT_MIN = 1667
local CCT_MAX = 25000

local function cct_to_xy(T)
    T = math.max(CCT_MIN, math.min(CCT_MAX, T))
    local x, y
    if T <= 4000 then
        x = (-0.2661239e9 / T^3) + (-0.2343580e6 / T^2) + (0.8776956e3 / T) + 0.179910
        y = (-1.1063814 * x^3) + (-1.34811020 * x^2) + (2.18555832 * x) - 0.20219683
    else
        x = (-3.0258469e9 / T^3) + (2.1070379e6 / T^2) + (0.2226347e3 / T) + 0.240390
        y = (3.0817580 * x^3) + (-5.87338670 * x^2) + (3.75112997 * x) - 0.37001483
    end
    return x, y
end

local function xy_to_uvp(x, y)
    local denom = -2 * x + 12 * y + 3
    if denom == 0 then return 0, 0 end
    return 4 * x / denom, 9 * y / denom
end

local function uvp_to_xy(up, vp)
    local denom = 6 * up - 16 * vp + 12
    if denom == 0 then return 0, 0 end
    return 9 * up / denom, 4 * vp / denom
end

local function apply_duv_correction(x, y, measured_duv, target_duv)
    local up, vp = xy_to_uvp(x, y)
    vp = vp + (target_duv - measured_duv) * 1.5
    return uvp_to_xy(up, vp)
end

local function xy_to_rgb(x, y)
    if y == 0 then y = 0.0001 end
    local X = x / y
    local Y = 1.0
    local Z = (1 - x - y) / y
    local r_lin =  3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
    local g_lin = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
    local b_lin =  0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
    r_lin = math.max(0, r_lin)
    g_lin = math.max(0, g_lin)
    b_lin = math.max(0, b_lin)
    local max_c = math.max(r_lin, g_lin, b_lin)
    if max_c > 0 then
        r_lin = r_lin / max_c
        g_lin = g_lin / max_c
        b_lin = b_lin / max_c
    end
    return r_lin ^ (1 / 2.2), g_lin ^ (1 / 2.2), b_lin ^ (1 / 2.2)
end

local function rgb_to_hsb(r, g, b)
    local max_c = math.max(r, g, b)
    local min_c = math.min(r, g, b)
    local delta = max_c - min_c
    local bri = max_c
    local s = (max_c == 0) and 0 or (delta / max_c)
    local h
    if delta == 0 then
        h = 0
    elseif max_c == r then
        h = 60 * (((g - b) / delta) % 6)
    elseif max_c == g then
        h = 60 * (((b - r) / delta) + 2)
    else
        h = 60 * (((r - g) / delta) + 4)
    end
    if h < 0 then h = h + 360 end
    return h, s, bri
end

local QUALITY = {
    CRI = { excellent = 95, good = 90, acceptable = 80 },
    R9  = { excellent = 90, good = 80, acceptable = 50 },
    DUV = { excellent = 0.003, good = 0.006, acceptable = 0.010 },
}

local function rate_quality(value, thresholds)
    if value >= thresholds.excellent then return "Excellent"
    elseif value >= thresholds.good then return "Good"
    elseif value >= thresholds.acceptable then return "Acceptable"
    else return "Poor"
    end
end

local function rate_duv(duv)
    local abs_duv = math.abs(duv)
    if abs_duv <= QUALITY.DUV.excellent then return "Excellent"
    elseif abs_duv <= QUALITY.DUV.good then return "Good"
    elseif abs_duv <= QUALITY.DUV.acceptable then return "Acceptable"
    else return "Poor"
    end
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

section("cct_to_xy – known reference values (Kang et al. approximation)")

-- 3200K tungsten: Kang formula Planckian locus values
-- (Note: Kang approximation differs slightly from CIE tables; these are the
-- formula's own reference outputs, confirmed against the Planckian locus)
do
    local x, y = cct_to_xy(3200)
    assert_near("3200K x", x, 0.4232, 0.005)
    assert_near("3200K y", y, 0.3974, 0.005)
end

-- 5600K: Kang formula Planckian locus values
do
    local x, y = cct_to_xy(5600)
    assert_near("5600K x", x, 0.3301, 0.005)
    assert_near("5600K y", y, 0.3391, 0.005)
end

-- 6500K: Kang formula values (note: D65 illuminant xy=0.3127,0.3290 is a
-- standard illuminant defined by spectral data, not the Planckian locus)
do
    local x, y = cct_to_xy(6500)
    assert_near("6500K x", x, 0.3135, 0.005)
    assert_near("6500K y", y, 0.3237, 0.005)
end

-- Boundary: T = 4000K (should use <= branch without crash)
do
    local x, y = cct_to_xy(4000)
    assert_near("4000K x (boundary)", x, 0.3805, 0.010)
    assert_near("4000K y (boundary)", y, 0.3768, 0.010)
end

section("xy_to_uvp / uvp_to_xy – roundtrip")

do
    local test_cases = {
        { 0.3127, 0.3290 },  -- D65
        { 0.4176, 0.3814 },  -- 3200K
        { 0.2500, 0.2500 },  -- arbitrary
    }
    for _, tc in ipairs(test_cases) do
        local x0, y0 = tc[1], tc[2]
        local up, vp = xy_to_uvp(x0, y0)
        local x1, y1 = uvp_to_xy(up, vp)
        assert_near(string.format("roundtrip x (%.4f,%.4f)", x0, y0), x1, x0, 0.0001)
        assert_near(string.format("roundtrip y (%.4f,%.4f)", x0, y0), y1, y0, 0.0001)
    end
end

section("apply_duv_correction – identity when delta=0")

do
    local x0, y0 = cct_to_xy(5600)
    local x1, y1 = apply_duv_correction(x0, y0, 0.003, 0.003)
    assert_near("identity x (same duv)", x1, x0, 0.0001)
    assert_near("identity y (same duv)", y1, y0, 0.0001)
end

do
    local x0, y0 = cct_to_xy(3200)
    local x1, y1 = apply_duv_correction(x0, y0, 0.000, 0.000)
    assert_near("identity x (both zero)", x1, x0, 0.0001)
    assert_near("identity y (both zero)", y1, y0, 0.0001)
end

section("apply_duv_correction – green shift correction")

do
    -- Light measured at +0.005 Duv (green). Target is 0.000.
    -- Correction should shift v' downward (toward magenta = lower v').
    local x0, y0 = cct_to_xy(5600)
    local _, vp0 = xy_to_uvp(x0, y0)
    local xc, yc = apply_duv_correction(x0, y0, 0.005, 0.000)
    local _, vpc = xy_to_uvp(xc, yc)
    -- v' should decrease (move toward magenta)
    if vpc < vp0 then
        print("  PASS  green correction shifts v' toward magenta")
        PASS = PASS + 1
    else
        print(string.format("  FAIL  green correction: v' %f → %f (should decrease)", vp0, vpc))
        FAIL = FAIL + 1
    end
end

section("xy_to_rgb – D65 white point → near-equal R,G,B")

do
    local r, g, b = xy_to_rgb(0.3127, 0.3290)
    -- After normalisation, all channels should be close to 1.0
    -- and relative differences should be small (near-white)
    local max_diff = math.max(math.abs(r - g), math.abs(g - b), math.abs(r - b))
    assert_near("D65 white R", r, 1.0, 0.05)
    assert_near("D65 white G", g, 1.0, 0.05)
    assert_near("D65 white B", b, 1.0, 0.05)
    assert_near("D65 white max channel diff", max_diff, 0, 0.10)
end

section("rgb_to_hsb – known values")

do
    -- Pure red: (1, 0, 0)
    local h, s, bri = rgb_to_hsb(1, 0, 0)
    assert_near("pure red H", h, 0, 1)
    assert_near("pure red S", s, 1.0, 0.001)
    assert_near("pure red B", bri, 1.0, 0.001)
end

do
    -- Pure green: (0, 1, 0)
    local h, s, bri = rgb_to_hsb(0, 1, 0)
    assert_near("pure green H", h, 120, 1)
    assert_near("pure green S", s, 1.0, 0.001)
    assert_near("pure green B", bri, 1.0, 0.001)
end

do
    -- White: (1, 1, 1)
    local h, s, bri = rgb_to_hsb(1, 1, 1)
    assert_near("white S", s, 0.0, 0.001)
    assert_near("white B", bri, 1.0, 0.001)
end

do
    -- Roundtrip: rgb → hsb → validate consistency
    local r0, g0, b0 = 0.6, 0.3, 0.8
    local h, s, bri = rgb_to_hsb(r0, g0, b0)
    -- Check hue is in [0, 360)
    if h >= 0 and h < 360 then
        print(string.format("  PASS  hsb hue in range [0,360): %.2f", h))
        PASS = PASS + 1
    else
        print(string.format("  FAIL  hsb hue out of range: %.2f", h))
        FAIL = FAIL + 1
    end
end

section("rate_quality – boundary values")

-- CRI boundaries
assert_equal("CRI 95 = Excellent", rate_quality(95,  QUALITY.CRI), "Excellent")
assert_equal("CRI 94 = Good",      rate_quality(94,  QUALITY.CRI), "Good")
assert_equal("CRI 90 = Good",      rate_quality(90,  QUALITY.CRI), "Good")
assert_equal("CRI 89 = Acceptable",rate_quality(89,  QUALITY.CRI), "Acceptable")
assert_equal("CRI 80 = Acceptable",rate_quality(80,  QUALITY.CRI), "Acceptable")
assert_equal("CRI 79 = Poor",      rate_quality(79,  QUALITY.CRI), "Poor")
assert_equal("CRI  0 = Poor",      rate_quality(0,   QUALITY.CRI), "Poor")

-- R9 boundaries
assert_equal("R9  90 = Excellent", rate_quality(90,  QUALITY.R9),  "Excellent")
assert_equal("R9  80 = Good",      rate_quality(80,  QUALITY.R9),  "Good")
assert_equal("R9  50 = Acceptable",rate_quality(50,  QUALITY.R9),  "Acceptable")
assert_equal("R9  49 = Poor",      rate_quality(49,  QUALITY.R9),  "Poor")

-- Duv (inverted: smaller = better)
assert_equal("Duv 0.000 = Excellent",  rate_duv(0.000),  "Excellent")
assert_equal("Duv 0.003 = Excellent",  rate_duv(0.003),  "Excellent")
assert_equal("Duv 0.004 = Good",       rate_duv(0.004),  "Good")
assert_equal("Duv 0.006 = Good",       rate_duv(0.006),  "Good")
assert_equal("Duv 0.007 = Acceptable", rate_duv(0.007),  "Acceptable")
assert_equal("Duv 0.010 = Acceptable", rate_duv(0.010),  "Acceptable")
assert_equal("Duv 0.011 = Poor",       rate_duv(0.011),  "Poor")
assert_equal("Duv -0.004 = Good",      rate_duv(-0.004), "Good")
assert_equal("Duv -0.011 = Poor",      rate_duv(-0.011), "Poor")

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", PASS, FAIL))
print(string.format("========================================"))

if FAIL > 0 then
    os.exit(1)
end
