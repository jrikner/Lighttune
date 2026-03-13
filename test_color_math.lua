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

local function assert_true(label, condition)
    if condition then
        print(string.format("  PASS  %s", label))
        PASS = PASS + 1
    else
        print(string.format("  FAIL  %s  (expected true)", label))
        FAIL = FAIL + 1
    end
end

local function section(name)
    print("\n[" .. name .. "]")
end

--------------------------------------------------------------------------------
-- Inline copies of color math (mirrors SekonicCalibrator.lua)
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
    CRI  = { excellent = 95, good = 90, acceptable = 80 },
    R9   = { excellent = 90, good = 80, acceptable = 50 },
    TLCI = { excellent = 90, good = 75, acceptable = 50 },
    DUV  = { excellent = 0.003, good = 0.006, acceptable = 0.010 },
}

local GEL_STEPS = {
    { threshold = 0.016, amount = "Full" },
    { threshold = 0.010, amount = "1/2"  },
    { threshold = 0.006, amount = "1/4"  },
    { threshold = 0.003, amount = "1/8"  },
}

local function gel_hint(duv)
    local abs_duv = math.abs(duv)
    local amount  = nil
    for _, step in ipairs(GEL_STEPS) do
        if abs_duv > step.threshold then
            amount = step.amount
            break
        end
    end
    if not amount then return nil end
    if duv > 0 then
        return string.format("%s Minus Green  (Duv %+.4f, green shift)", amount, duv)
    else
        return string.format("%s Plus Green   (Duv %+.4f, magenta shift)", amount, duv)
    end
end

local B64_CHARS  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LOOKUP = {}
for i = 1, #B64_CHARS do B64_LOOKUP[B64_CHARS:sub(i, i)] = i - 1 end

local function base64_encode(data)
    local result = {}
    for i = 1, #data, 3 do
        local a = data:byte(i)     or 0
        local b = data:byte(i + 1) or 0
        local c = data:byte(i + 2) or 0
        local n = (a << 16) | (b << 8) | c
        result[#result + 1] = B64_CHARS:sub(((n >> 18) & 63) + 1, ((n >> 18) & 63) + 1)
        result[#result + 1] = B64_CHARS:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
        result[#result + 1] = B64_CHARS:sub(((n >> 6)  & 63) + 1, ((n >> 6)  & 63) + 1)
        result[#result + 1] = B64_CHARS:sub(( n        & 63) + 1, ( n        & 63) + 1)
    end
    local encoded = table.concat(result)
    local pad = (3 - #data % 3) % 3
    return encoded:sub(1, #encoded - pad) .. ("="):rep(pad)
end

local function base64_decode(data)
    data = data:gsub("[^%w%+%/%=]", "")
    local result = {}
    for i = 1, #data, 4 do
        local a = B64_LOOKUP[data:sub(i,   i)]   or 0
        local b = B64_LOOKUP[data:sub(i+1, i+1)] or 0
        local c = B64_LOOKUP[data:sub(i+2, i+2)] or 0
        local d = B64_LOOKUP[data:sub(i+3, i+3)] or 0
        local n = (a << 18) | (b << 12) | (c << 6) | d
        result[#result + 1] = string.char((n >> 16) & 0xFF)
        if data:sub(i+2, i+2) ~= "=" then
            result[#result + 1] = string.char((n >> 8) & 0xFF)
        end
        if data:sub(i+3, i+3) ~= "=" then
            result[#result + 1] = string.char(n & 0xFF)
        end
    end
    return table.concat(result)
end

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

-- ── Inline DB helpers (mirrors SekonicCalibrator.lua Section 2b) ─────────────

local function json_encode_metric(m)
    if not m then return "null" end
    return string.format(
        '{"value":%s,"params":"%s","date":"%s","contributor":"%s"}',
        tostring(m.value),
        (m.params or ""):gsub('"', '\\"'),
        (m.date or ""):gsub('"', '\\"'),
        (m.contributor or ""):gsub('"', '\\"')
    )
end

local function json_encode_db_record(rec)
    return string.format(
        '{"make":"%s","model":"%s","kelvin":%d,"cri":%s,"r9":%s,"tlci":%s,"duv":%s}',
        (rec.make  or ""):gsub('"', '\\"'),
        (rec.model or ""):gsub('"', '\\"'),
        rec.kelvin or 0,
        json_encode_metric(rec.cri),
        json_encode_metric(rec.r9),
        json_encode_metric(rec.tlci),
        json_encode_metric(rec.duv)
    )
end

local function json_encode_db_array(records)
    if #records == 0 then return "[]" end
    local parts = {}
    for _, rec in ipairs(records) do parts[#parts + 1] = json_encode_db_record(rec) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n]"
end

local function json_get_str(json, key)
    return json:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

local function json_get_num(json, key)
    return tonumber(json:match('"' .. key .. '"%s*:%s*(-?%d+%.?%d*)'))
end

local function json_parse_metric(json_block, key)
    if json_block:find('"' .. key .. '"%s*:%s*null') then return nil end
    local sub = json_block:match('"' .. key .. '"%s*:%s*(%b{})')
    if not sub then return nil end
    local val = json_get_num(sub, "value")
    if not val then return nil end
    return {
        value       = val,
        params      = json_get_str(sub, "params")      or "",
        date        = json_get_str(sub, "date")        or "",
        contributor = json_get_str(sub, "contributor") or "",
    }
end

local function json_parse_db_array(content)
    if not content or content:match("^%s*%[%s*%]%s*$") then return {} end
    local records = {}
    for block in content:gmatch("%b{}") do
        local make   = json_get_str(block, "make")
        local model  = json_get_str(block, "model")
        local kelvin = json_get_num(block, "kelvin")
        if make and model and kelvin then
            records[#records + 1] = {
                make   = make,
                model  = model,
                kelvin = kelvin,
                cri    = json_parse_metric(block, "cri"),
                r9     = json_parse_metric(block, "r9"),
                tlci   = json_parse_metric(block, "tlci"),
                duv    = json_parse_metric(block, "duv"),
            }
        end
    end
    return records
end

local function upsert_fixture_record(records, db_entry, contributor)
    local date       = "2026-01-01"  -- fixed date for deterministic tests
    contributor      = contributor or "anonymous"
    local params_str = string.format("%dK Duv:%+.4f", db_entry.cct_measured, db_entry.duv)

    local existing = nil
    for _, rec in ipairs(records) do
        if rec.make == db_entry.make
           and rec.model  == db_entry.model
           and rec.kelvin == db_entry.kelvin then
            existing = rec; break
        end
    end

    local function make_metric(val)
        if not val then return nil end
        return { value = val, params = params_str, date = date, contributor = contributor }
    end

    if not existing then
        records[#records + 1] = {
            make   = db_entry.make,
            model  = db_entry.model,
            kelvin = db_entry.kelvin,
            cri    = make_metric(db_entry.cri),
            r9     = make_metric(db_entry.r9),
            tlci   = make_metric(db_entry.tlci),
            duv    = make_metric(db_entry.duv),
        }
    else
        if db_entry.cri and (not existing.cri or db_entry.cri > existing.cri.value) then
            existing.cri = make_metric(db_entry.cri)
        end
        if db_entry.r9 and (not existing.r9 or db_entry.r9 > existing.r9.value) then
            existing.r9 = make_metric(db_entry.r9)
        end
        if db_entry.tlci and (not existing.tlci or db_entry.tlci > existing.tlci.value) then
            existing.tlci = make_metric(db_entry.tlci)
        end
        if db_entry.duv and
           (not existing.duv or math.abs(db_entry.duv) < math.abs(existing.duv.value)) then
            existing.duv = make_metric(db_entry.duv)
        end
    end
end

local function sort_fixture_records(records)
    table.sort(records, function(a, b)
        if a.make  ~= b.make  then return a.make  < b.make  end
        if a.model ~= b.model then return a.model < b.model end
        return a.kelvin < b.kelvin
    end)
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

section("cct_to_xy – known reference values (Kang et al. approximation)")

do
    local x, y = cct_to_xy(3200)
    assert_near("3200K x", x, 0.4232, 0.005)
    assert_near("3200K y", y, 0.3974, 0.005)
end

do
    local x, y = cct_to_xy(5600)
    assert_near("5600K x", x, 0.3301, 0.005)
    assert_near("5600K y", y, 0.3391, 0.005)
end

do
    local x, y = cct_to_xy(6500)
    assert_near("6500K x", x, 0.3135, 0.005)
    assert_near("6500K y", y, 0.3237, 0.005)
end

do
    local x, y = cct_to_xy(4000)
    assert_near("4000K x (boundary)", x, 0.3805, 0.010)
    assert_near("4000K y (boundary)", y, 0.3768, 0.010)
end

section("xy_to_uvp / uvp_to_xy – roundtrip")

do
    local test_cases = {
        { 0.3127, 0.3290 },
        { 0.4176, 0.3814 },
        { 0.2500, 0.2500 },
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
    local x0, y0 = cct_to_xy(5600)
    local _, vp0 = xy_to_uvp(x0, y0)
    local xc, yc = apply_duv_correction(x0, y0, 0.005, 0.000)
    local _, vpc = xy_to_uvp(xc, yc)
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
    local max_diff = math.max(math.abs(r - g), math.abs(g - b), math.abs(r - b))
    assert_near("D65 white R", r, 1.0, 0.05)
    assert_near("D65 white G", g, 1.0, 0.05)
    assert_near("D65 white B", b, 1.0, 0.05)
    assert_near("D65 white max channel diff", max_diff, 0, 0.10)
end

section("rgb_to_hsb – known values")

do
    local h, s, bri = rgb_to_hsb(1, 0, 0)
    assert_near("pure red H", h, 0, 1)
    assert_near("pure red S", s, 1.0, 0.001)
    assert_near("pure red B", bri, 1.0, 0.001)
end

do
    local h, s, bri = rgb_to_hsb(0, 1, 0)
    assert_near("pure green H", h, 120, 1)
    assert_near("pure green S", s, 1.0, 0.001)
    assert_near("pure green B", bri, 1.0, 0.001)
end

do
    local h, s, bri = rgb_to_hsb(1, 1, 1)
    assert_near("white S", s, 0.0, 0.001)
    assert_near("white B", bri, 1.0, 0.001)
end

do
    local r0, g0, b0 = 0.6, 0.3, 0.8
    local h, s, bri = rgb_to_hsb(r0, g0, b0)
    if h >= 0 and h < 360 then
        print(string.format("  PASS  hsb hue in range [0,360): %.2f", h))
        PASS = PASS + 1
    else
        print(string.format("  FAIL  hsb hue out of range: %.2f", h))
        FAIL = FAIL + 1
    end
end

section("rate_quality – boundary values")

assert_equal("CRI 95 = Excellent", rate_quality(95,  QUALITY.CRI), "Excellent")
assert_equal("CRI 94 = Good",      rate_quality(94,  QUALITY.CRI), "Good")
assert_equal("CRI 90 = Good",      rate_quality(90,  QUALITY.CRI), "Good")
assert_equal("CRI 89 = Acceptable",rate_quality(89,  QUALITY.CRI), "Acceptable")
assert_equal("CRI 80 = Acceptable",rate_quality(80,  QUALITY.CRI), "Acceptable")
assert_equal("CRI 79 = Poor",      rate_quality(79,  QUALITY.CRI), "Poor")
assert_equal("CRI  0 = Poor",      rate_quality(0,   QUALITY.CRI), "Poor")

assert_equal("R9  90 = Excellent", rate_quality(90,  QUALITY.R9),  "Excellent")
assert_equal("R9  80 = Good",      rate_quality(80,  QUALITY.R9),  "Good")
assert_equal("R9  50 = Acceptable",rate_quality(50,  QUALITY.R9),  "Acceptable")
assert_equal("R9  49 = Poor",      rate_quality(49,  QUALITY.R9),  "Poor")

assert_equal("Duv 0.000 = Excellent",  rate_duv(0.000),  "Excellent")
assert_equal("Duv 0.003 = Excellent",  rate_duv(0.003),  "Excellent")
assert_equal("Duv 0.004 = Good",       rate_duv(0.004),  "Good")
assert_equal("Duv 0.006 = Good",       rate_duv(0.006),  "Good")
assert_equal("Duv 0.007 = Acceptable", rate_duv(0.007),  "Acceptable")
assert_equal("Duv 0.010 = Acceptable", rate_duv(0.010),  "Acceptable")
assert_equal("Duv 0.011 = Poor",       rate_duv(0.011),  "Poor")
assert_equal("Duv -0.004 = Good",      rate_duv(-0.004), "Good")
assert_equal("Duv -0.011 = Poor",      rate_duv(-0.011), "Poor")

section("rate_quality – TLCI thresholds")
assert_equal("TLCI  90 = Excellent",  rate_quality(90, QUALITY.TLCI), "Excellent")
assert_equal("TLCI  89 = Good",       rate_quality(89, QUALITY.TLCI), "Good")
assert_equal("TLCI  75 = Good",       rate_quality(75, QUALITY.TLCI), "Good")
assert_equal("TLCI  74 = Acceptable", rate_quality(74, QUALITY.TLCI), "Acceptable")
assert_equal("TLCI  50 = Acceptable", rate_quality(50, QUALITY.TLCI), "Acceptable")
assert_equal("TLCI  49 = Poor",       rate_quality(49, QUALITY.TLCI), "Poor")
assert_equal("TLCI   0 = Poor",       rate_quality(0,  QUALITY.TLCI), "Poor")

section("gel_hint – direction and amount")

assert_equal("Duv  0.000 = nil",     gel_hint( 0.000), nil)
assert_equal("Duv +0.002 = nil",     gel_hint( 0.002), nil)
assert_equal("Duv -0.002 = nil",     gel_hint(-0.002), nil)
assert_equal("Duv +0.003 = nil",     gel_hint( 0.003), nil)

do
    local h = gel_hint(0.004)
    assert_equal("Duv +0.004 starts with 1/8 Minus", h and h:sub(1, 11) or nil, "1/8 Minus G")
end
do
    local h = gel_hint(-0.004)
    assert_equal("Duv -0.004 starts with 1/8 Plus",  h and h:sub(1, 10) or nil, "1/8 Plus G")
end

do
    local h = gel_hint(0.006)
    assert_equal("Duv +0.006 = 1/8 (at 1/4 boundary)", h and h:sub(1, 11) or nil, "1/8 Minus G")
end
do
    local h = gel_hint(0.007)
    assert_equal("Duv +0.007 = 1/4 Minus Green", h and h:sub(1, 11) or nil, "1/4 Minus G")
end

do
    local h = gel_hint(0.012)
    assert_equal("Duv +0.012 = 1/2 Minus Green", h and h:sub(1, 11) or nil, "1/2 Minus G")
end
do
    local h = gel_hint(-0.012)
    assert_equal("Duv -0.012 = 1/2 Plus Green",  h and h:sub(1, 10) or nil, "1/2 Plus G")
end

do
    local h = gel_hint(0.020)
    assert_equal("Duv +0.020 = Full Minus Green", h and h:sub(1, 12) or nil, "Full Minus G")
end
do
    local h = gel_hint(-0.020)
    assert_equal("Duv -0.020 = Full Plus Green",  h and h:sub(1, 11) or nil, "Full Plus G")
end

section("base64_encode – known vectors (RFC 4648)")
assert_equal("base64 ''",       base64_encode(""),       "")
assert_equal("base64 'f'",      base64_encode("f"),      "Zg==")
assert_equal("base64 'fo'",     base64_encode("fo"),     "Zm8=")
assert_equal("base64 'foo'",    base64_encode("foo"),    "Zm9v")
assert_equal("base64 'foobar'", base64_encode("foobar"), "Zm9vYmFy")

section("base64_decode – roundtrip")
assert_equal("decode ''",           base64_decode(""),         "")
assert_equal("decode 'Zg=='",       base64_decode("Zg=="),     "f")
assert_equal("decode 'Zm8='",       base64_decode("Zm8="),     "fo")
assert_equal("decode 'Zm9v'",       base64_decode("Zm9v"),     "foo")
assert_equal("decode 'Zm9vYmFy'",   base64_decode("Zm9vYmFy"),"foobar")

do
    -- roundtrip: encode then decode should return original
    local orig = "Hello, world! 1234 \x00\xFF"
    assert_equal("encode/decode roundtrip", base64_decode(base64_encode(orig)), orig)
end

section("json_encode_db_array / json_parse_db_array – roundtrip")

do
    -- Empty array
    local encoded = json_encode_db_array({})
    assert_equal("empty array encodes to []", encoded, "[]")
    local parsed = json_parse_db_array("[]")
    assert_equal("[] parses to 0 records", #parsed, 0)
end

do
    -- Single record with all metrics
    local rec = {
        make   = "Aputure",
        model  = "600X Pro",
        kelvin = 5600,
        cri    = { value = 95, params = "5572K Duv:+0.0030", date = "2026-03-13", contributor = "jrikner" },
        r9     = { value = 88, params = "5572K Duv:+0.0030", date = "2026-03-13", contributor = "jrikner" },
        tlci   = { value = 91, params = "5572K Duv:+0.0030", date = "2026-03-13", contributor = "jrikner" },
        duv    = { value = 0.003, params = "5572K Duv:+0.0030", date = "2026-03-13", contributor = "jrikner" },
    }
    local encoded = json_encode_db_array({ rec })
    local parsed  = json_parse_db_array(encoded)
    assert_equal("single record: count",       #parsed,              1)
    assert_equal("single record: make",        parsed[1].make,       "Aputure")
    assert_equal("single record: model",       parsed[1].model,      "600X Pro")
    assert_equal("single record: kelvin",      parsed[1].kelvin,     5600)
    assert_equal("single record: cri.value",   parsed[1].cri.value,  95)
    assert_equal("single record: r9.value",    parsed[1].r9.value,   88)
    assert_equal("single record: tlci.value",  parsed[1].tlci.value, 91)
    assert_near ("single record: duv.value",   parsed[1].duv.value,  0.003, 0.0001)
    assert_equal("single record: contributor", parsed[1].cri.contributor, "jrikner")
end

do
    -- Record with nil tlci (C-700/C-800 case)
    local rec = {
        make   = "Arri",
        model  = "SkyPanel S60",
        kelvin = 3200,
        cri    = { value = 97, params = "3180K Duv:-0.0010", date = "2026-03-13", contributor = "test" },
        r9     = { value = 92, params = "3180K Duv:-0.0010", date = "2026-03-13", contributor = "test" },
        tlci   = nil,
        duv    = { value = -0.001, params = "3180K Duv:-0.0010", date = "2026-03-13", contributor = "test" },
    }
    local encoded = json_encode_db_array({ rec })
    local parsed  = json_parse_db_array(encoded)
    assert_equal("nil tlci: count",     #parsed,         1)
    assert_equal("nil tlci: tlci=nil",  parsed[1].tlci,  nil)
    assert_equal("nil tlci: cri.value", parsed[1].cri.value, 97)
end

section("upsert_fixture_record – insert and update logic")

do
    -- Insert new record
    local records = {}
    local entry = {
        make = "TestMake", model = "TestModel", kelvin = 5600,
        cri = 90, r9 = 80, tlci = 85, duv = 0.005, cct_measured = 5580,
    }
    upsert_fixture_record(records, entry, "user1")
    assert_equal("insert: count",      #records,              1)
    assert_equal("insert: make",       records[1].make,       "TestMake")
    assert_equal("insert: cri.value",  records[1].cri.value,  90)
    assert_equal("insert: r9.value",   records[1].r9.value,   80)
    assert_equal("insert: tlci.value", records[1].tlci.value, 85)
    assert_near ("insert: duv.value",  records[1].duv.value,  0.005, 0.0001)
end

do
    -- Update: better values replace existing
    local records = {}
    local entry1 = {
        make = "TestMake", model = "TestModel", kelvin = 5600,
        cri = 90, r9 = 80, tlci = 85, duv = 0.005, cct_measured = 5580,
    }
    upsert_fixture_record(records, entry1, "user1")

    local entry2 = {
        make = "TestMake", model = "TestModel", kelvin = 5600,
        cri = 95, r9 = 75, tlci = 91, duv = 0.002, cct_measured = 5595,
    }
    upsert_fixture_record(records, entry2, "user1")

    assert_equal("update: still 1 record", #records, 1)
    -- CRI improved: 90 → 95
    assert_equal("update: cri improved",   records[1].cri.value,  95)
    -- R9 did NOT improve: 80 > 75, keep 80
    assert_equal("update: r9 unchanged",   records[1].r9.value,   80)
    -- TLCI improved: 85 → 91
    assert_equal("update: tlci improved",  records[1].tlci.value, 91)
    -- Duv improved: |0.005| > |0.002|
    assert_near ("update: duv improved",   records[1].duv.value,  0.002, 0.0001)
end

do
    -- New kelvin = new record; total 2 records
    local records = {}
    local entry1 = {
        make = "TestMake", model = "TestModel", kelvin = 5600,
        cri = 90, r9 = 80, duv = 0.003, cct_measured = 5580,
    }
    local entry2 = {
        make = "TestMake", model = "TestModel", kelvin = 3200,
        cri = 88, r9 = 77, duv = -0.002, cct_measured = 3180,
    }
    upsert_fixture_record(records, entry1, "user1")
    upsert_fixture_record(records, entry2, "user1")
    assert_equal("two kelvin: count",        #records,              2)
    assert_equal("two kelvin: k1",           records[1].kelvin,     5600)
    assert_equal("two kelvin: k2",           records[2].kelvin,     3200)
end

do
    -- Duv update: negative Duv closer to zero replaces positive
    local records = {}
    local entry1 = {
        make = "X", model = "Y", kelvin = 5600,
        cri = 90, r9 = 80, duv = -0.008, cct_measured = 5580,
    }
    upsert_fixture_record(records, entry1, "u")
    local entry2 = {
        make = "X", model = "Y", kelvin = 5600,
        cri = 90, r9 = 80, duv = 0.003, cct_measured = 5590,
    }
    upsert_fixture_record(records, entry2, "u")
    -- |0.003| < |-0.008|, so 0.003 should win
    assert_near("duv closer to zero wins", records[1].duv.value, 0.003, 0.0001)
end

section("sort_fixture_records – ordering")

do
    local records = {
        { make = "Chroma-Q", model = "Space Force", kelvin = 5600, cri=nil, r9=nil, tlci=nil, duv=nil },
        { make = "Aputure",  model = "600X Pro",    kelvin = 5600, cri=nil, r9=nil, tlci=nil, duv=nil },
        { make = "Aputure",  model = "300X",        kelvin = 5600, cri=nil, r9=nil, tlci=nil, duv=nil },
        { make = "Aputure",  model = "600X Pro",    kelvin = 3200, cri=nil, r9=nil, tlci=nil, duv=nil },
        { make = "Arri",     model = "SkyPanel S60",kelvin = 5600, cri=nil, r9=nil, tlci=nil, duv=nil },
    }
    sort_fixture_records(records)
    assert_equal("sort[1].make",   records[1].make,   "Aputure")
    assert_equal("sort[1].model",  records[1].model,  "300X")
    assert_equal("sort[2].model",  records[2].model,  "600X Pro")
    assert_equal("sort[2].kelvin", records[2].kelvin, 3200)
    assert_equal("sort[3].kelvin", records[3].kelvin, 5600)
    assert_equal("sort[4].make",   records[4].make,   "Arri")
    assert_equal("sort[5].make",   records[5].make,   "Chroma-Q")
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", PASS, FAIL))
print(string.format("========================================"))

if FAIL > 0 then
    os.exit(1)
end
