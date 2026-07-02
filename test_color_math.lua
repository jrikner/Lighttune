-- test_color_math.lua
-- Standalone Lua 5.4 unit tests for SekonicCalibrator domain modules.
-- Run with: lua5.4 test_color_math.lua

package.path = package.path .. ";./lua/?.lua"

local color_math  = require("color_math")
local fixture_db = require("fixture_db")
local goals      = require("goals")

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
        print(string.format("  FAIL  %s  (got '%s', expected '%s')",
            label, tostring(got), tostring(expected)))
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

local function assert_false(label, condition)
    if not condition then
        print(string.format("  PASS  %s", label))
        PASS = PASS + 1
    else
        print(string.format("  FAIL  %s  (expected false)", label))
        FAIL = FAIL + 1
    end
end

local function section(name)
    print("\n[" .. name .. "]")
end

-- Aliases for test readability
local cct_to_xy = color_math.cct_to_xy
local xy_to_uvp = color_math.xy_to_uvp
local uvp_to_xy = color_math.uvp_to_xy
local apply_duv_correction = color_math.apply_duv_correction
local xy_to_rgb = color_math.xy_to_rgb
local rgb_to_hsb = color_math.rgb_to_hsb
local rate_quality = color_math.rate_quality
local rate_duv = color_math.rate_duv
local gel_hint = color_math.gel_hint
local QUALITY = goals.QUALITY

local json_encode_db_record = fixture_db.json_encode_db_record
local json_encode_db_array = fixture_db.json_encode_db_array
local function json_parse_db_array(content)
    return select(1, fixture_db.json_parse_db_array(content))
end
local recompute_best_flags = fixture_db.recompute_best_flags
local append_fixture_record = fixture_db.append_fixture_record
local sort_fixture_records = fixture_db.sort_fixture_records
local find_best_for_fixture = fixture_db.find_best_for_fixture

section("cct_to_xy – known reference values (Kang et al.)")
do local x,y=cct_to_xy(3200); assert_near("3200K x",x,0.4232,0.005); assert_near("3200K y",y,0.3974,0.005) end
do local x,y=cct_to_xy(5600); assert_near("5600K x",x,0.3301,0.005); assert_near("5600K y",y,0.3391,0.005) end
do local x,y=cct_to_xy(6500); assert_near("6500K x",x,0.3135,0.005); assert_near("6500K y",y,0.3237,0.005) end
do local x,y=cct_to_xy(4000); assert_near("4000K x (boundary)",x,0.3805,0.010); assert_near("4000K y (boundary)",y,0.3768,0.010) end

section("xy_to_uvp / uvp_to_xy – roundtrip")
do
    for _,tc in ipairs({{0.3127,0.3290},{0.4176,0.3814},{0.2500,0.2500}}) do
        local x0,y0=tc[1],tc[2]; local up,vp=xy_to_uvp(x0,y0); local x1,y1=uvp_to_xy(up,vp)
        assert_near(string.format("roundtrip x (%.4f,%.4f)",x0,y0),x1,x0,0.0001)
        assert_near(string.format("roundtrip y (%.4f,%.4f)",x0,y0),y1,y0,0.0001)
    end
end

section("apply_duv_correction – identity and direction")
do local x0,y0=cct_to_xy(5600); local x1,y1=apply_duv_correction(x0,y0,0.003,0.003)
   assert_near("identity x",x1,x0,0.0001); assert_near("identity y",y1,y0,0.0001) end
do local x0,y0=cct_to_xy(5600); local _,vp0=xy_to_uvp(x0,y0)
   local xc,yc=apply_duv_correction(x0,y0,0.005,0.000); local _,vpc=xy_to_uvp(xc,yc)
   if vpc<vp0 then print("  PASS  green correction shifts v' toward magenta"); PASS=PASS+1
   else print("  FAIL  green correction direction wrong"); FAIL=FAIL+1 end end

section("xy_to_rgb / rgb_to_hsb")
do local r,g,b=xy_to_rgb(0.3127,0.3290)
   assert_near("D65 R",r,1.0,0.05); assert_near("D65 G",g,1.0,0.05); assert_near("D65 B",b,1.0,0.05) end
do local h,s,bri=rgb_to_hsb(1,0,0)
   assert_near("red H",h,0,1); assert_near("red S",s,1.0,0.001); assert_near("red B",bri,1.0,0.001) end
do local h,s,bri=rgb_to_hsb(0,1,0)
   assert_near("green H",h,120,1) end
do local h,s,bri=rgb_to_hsb(1,1,1)
   assert_near("white S",s,0.0,0.001); assert_near("white B",bri,1.0,0.001) end

section("rate_quality – CRI/R9/TLCI/Duv boundaries")
assert_equal("CRI 95=Excellent",  rate_quality(95,QUALITY.CRI),"Excellent")
assert_equal("CRI 90=Good",       rate_quality(90,QUALITY.CRI),"Good")
assert_equal("CRI 80=Acceptable", rate_quality(80,QUALITY.CRI),"Acceptable")
assert_equal("CRI 79=Poor",       rate_quality(79,QUALITY.CRI),"Poor")
assert_equal("R9  90=Excellent",  rate_quality(90,QUALITY.R9), "Excellent")
assert_equal("R9  50=Acceptable", rate_quality(50,QUALITY.R9), "Acceptable")
assert_equal("R9  49=Poor",       rate_quality(49,QUALITY.R9), "Poor")
assert_equal("TLCI 90=Excellent", rate_quality(90,QUALITY.TLCI),"Excellent")
assert_equal("TLCI 75=Good",      rate_quality(75,QUALITY.TLCI),"Good")
assert_equal("TLCI 74=Acceptable",rate_quality(74,QUALITY.TLCI),"Acceptable")
assert_equal("TLCI  0=Poor",      rate_quality(0, QUALITY.TLCI),"Poor")
assert_equal("Duv 0.000=Excellent",rate_duv(0.000),"Excellent")
assert_equal("Duv 0.003=Excellent",rate_duv(0.003),"Excellent")
assert_equal("Duv 0.006=Good",     rate_duv(0.006),"Good")
assert_equal("Duv 0.010=Acceptable",rate_duv(0.010),"Acceptable")
assert_equal("Duv 0.011=Poor",     rate_duv(0.011),"Poor")
assert_equal("Duv -0.011=Poor",    rate_duv(-0.011),"Poor")

section("gel_hint – direction and amount")
assert_equal("Duv 0.000=nil",  gel_hint(0.000),nil)
assert_equal("Duv +0.003=nil", gel_hint(0.003),nil)
do local h=gel_hint(0.004);  assert_equal("Duv +0.004=1/8 Minus",h and h:sub(1,11) or nil,"1/8 Minus G") end
do local h=gel_hint(-0.004); assert_equal("Duv -0.004=1/8 Plus", h and h:sub(1,10) or nil,"1/8 Plus G")  end
do local h=gel_hint(0.006);  assert_equal("Duv +0.006=1/8 (at boundary)",h and h:sub(1,11) or nil,"1/8 Minus G") end
do local h=gel_hint(0.007);  assert_equal("Duv +0.007=1/4 Minus",h and h:sub(1,11) or nil,"1/4 Minus G") end
do local h=gel_hint(0.012);  assert_equal("Duv +0.012=1/2 Minus",h and h:sub(1,11) or nil,"1/2 Minus G") end
do local h=gel_hint(-0.012); assert_equal("Duv -0.012=1/2 Plus", h and h:sub(1,10) or nil,"1/2 Plus G")  end
do local h=gel_hint(0.020);  assert_equal("Duv +0.020=Full Minus",h and h:sub(1,12) or nil,"Full Minus G") end
do local h=gel_hint(-0.020); assert_equal("Duv -0.020=Full Plus", h and h:sub(1,11) or nil,"Full Plus G")  end

section("json_encode_db_record / json_parse_db_array – flat schema roundtrip")

do  -- empty array
    assert_equal("empty array",json_encode_db_array({}),"[]")
    assert_equal("[] parses to 0 records",#json_parse_db_array("[]"),0)
end

do  -- single record with all fields
    local rec={make="Aputure",model="600X Pro",kelvin=5600,date="2026-03-13",contributor="jrikner",
               cct=5572,duv=0.003,cri=95,r9=88,tlci=91,best_cri=true,best_r9=true,best_tlci=true,best_duv=true}
    local enc=json_encode_db_array({rec})
    local parsed=json_parse_db_array(enc)
    assert_equal("count",#parsed,1)
    assert_equal("make",parsed[1].make,"Aputure")
    assert_equal("model",parsed[1].model,"600X Pro")
    assert_equal("kelvin",parsed[1].kelvin,5600)
    assert_equal("date",parsed[1].date,"2026-03-13")
    assert_equal("contributor",parsed[1].contributor,"jrikner")
    assert_equal("cct",parsed[1].cct,5572)
    assert_near ("duv",parsed[1].duv,0.003,0.0001)
    assert_equal("cri",parsed[1].cri,95)
    assert_equal("r9", parsed[1].r9, 88)
    assert_equal("tlci",parsed[1].tlci,91)
    assert_true ("best_cri flag",  parsed[1].best_cri)
    assert_true ("best_r9 flag",   parsed[1].best_r9)
    assert_true ("best_tlci flag", parsed[1].best_tlci)
    assert_true ("best_duv flag",  parsed[1].best_duv)
end

do  -- nil tlci (C-700 measurement)
    local rec={make="Arri",model="SkyPanel",kelvin=3200,date="2026-03-13",contributor="test",
               cct=3180,duv=-0.001,cri=97,r9=92,tlci=nil}
    local enc=json_encode_db_array({rec})
    local parsed=json_parse_db_array(enc)
    assert_equal("nil tlci field",parsed[1].tlci,nil)
    assert_equal("cri preserved",  parsed[1].cri,97)
end

do  -- negative Duv round-trips correctly
    local rec={make="X",model="Y",kelvin=5600,date="2026-01-01",contributor="t",
               cct=5580,duv=-0.0123,cri=90,r9=80}
    local parsed=json_parse_db_array(json_encode_db_array({rec}))
    assert_near("negative duv roundtrip",parsed[1].duv,-0.0123,0.0001)
end

section("best_* flags not written when false/nil")

do
    local rec={make="X",model="Y",kelvin=5600,date="2026-01-01",contributor="t",
               cct=5580,duv=0.003,cri=90,r9=80,best_cri=nil,best_r9=nil}
    local enc=json_encode_db_record(rec)
    -- best_cri:true should NOT appear in the JSON when nil
    assert_false("best_cri absent when nil", enc:find('"best_cri"')~=nil)
end


section("json_parse_db_array – quote in make/model")
do
    local rec = {make='Acme "Pro" 600', model="X", kelvin=5600, date="2026-01-01", contributor="t",
                 cct=5580, duv=0.003, cri=90, r9=80}
    local enc = json_encode_db_array({rec})
    local parsed, skipped = fixture_db.json_parse_db_array(enc)
    assert_equal("quote make roundtrip count", #parsed, 1)
    assert_equal("quote make preserved", parsed[1].make, 'Acme "Pro" 600')
    assert_equal("quote skipped", skipped or 0, 0)
end

do
    local parsed, skipped = fixture_db.json_parse_db_array('[{broken json}]')
    assert_true("malformed block skipped", (skipped or 0) >= 1)
end

section("recompute_best_flags – correctness")

do  -- single record: all bests belong to it
    local records={{make="A",model="B",kelvin=5600,cri=90,r9=80,tlci=88,duv=0.003}}
    recompute_best_flags(records)
    assert_true ("single: best_cri",  records[1].best_cri)
    assert_true ("single: best_r9",   records[1].best_r9)
    assert_true ("single: best_tlci", records[1].best_tlci)
    assert_true ("single: best_duv",  records[1].best_duv)
end

do  -- two records same fixture/kelvin; different metrics win
    local records={
        {make="A",model="B",kelvin=5600,cri=95,r9=75,tlci=nil,duv=0.008},
        {make="A",model="B",kelvin=5600,cri=88,r9=90,tlci=nil,duv=0.002},
    }
    recompute_best_flags(records)
    assert_true ("cri winner (rec 1)",  records[1].best_cri)
    assert_false("cri loser (rec 2)",   records[2].best_cri)
    assert_false("r9 loser (rec 1)",    records[1].best_r9)
    assert_true ("r9 winner (rec 2)",   records[2].best_r9)
    -- Duv: |0.002| < |0.008|, so rec 2 wins
    assert_false("duv loser (rec 1)",   records[1].best_duv)
    assert_true ("duv winner (rec 2)",  records[2].best_duv)
end

do  -- two fixtures (different models): best flags independent
    local records={
        {make="A",model="M1",kelvin=5600,cri=90,r9=80,duv=0.003},
        {make="A",model="M2",kelvin=5600,cri=85,r9=85,duv=0.001},
    }
    recompute_best_flags(records)
    -- Each model has exactly one record, so both are best within their group
    assert_true("M1 best_cri", records[1].best_cri)
    assert_true("M2 best_cri", records[2].best_cri)
end

do  -- negative Duv: |−0.001| < |+0.005|, so negative value wins
    local records={
        {make="Z",model="Z",kelvin=5600,cri=90,r9=80,duv=0.005},
        {make="Z",model="Z",kelvin=5600,cri=90,r9=80,duv=-0.001},
    }
    recompute_best_flags(records)
    assert_false("positive duv not best",  records[1].best_duv)
    assert_true ("negative duv is best",   records[2].best_duv)
end

section("append_fixture_record – never replaces, always appends")

do
    local records={}
    local e1={make="A",model="B",kelvin=5600,date="2026-01-01",cct=5572,duv=0.005,cri=90,r9=80}
    append_fixture_record(records,e1)
    assert_equal("after 1st append: count",#records,1)
    assert_equal("after 1st: cri",records[1].cri,90)
    assert_true ("after 1st: best_cri set",records[1].best_cri)

    local e2={make="A",model="B",kelvin=5600,date="2026-01-02",cct=5585,duv=0.002,cri=95,r9=85}
    append_fixture_record(records,e2)
    assert_equal("after 2nd append: count",#records,2)   -- both kept
    assert_equal("first record cri unchanged",records[1].cri,90)
    assert_equal("second record cri",records[2].cri,95)
    -- After recompute: rec 2 has best CRI (95 > 90)
    assert_false("rec 1 no longer best_cri",records[1].best_cri)
    assert_true ("rec 2 is best_cri",        records[2].best_cri)
    -- rec 1 still best_r9 (80 > 85 is false, so rec 2 wins r9 too)
    -- wait: 85 > 80 so rec 2 has best r9 as well
    assert_false("rec 1 not best_r9 (80<85)", records[1].best_r9)
    assert_true ("rec 2 best_r9 (85)",         records[2].best_r9)
    -- Duv: |0.002| < |0.005|, rec 2 wins
    assert_true ("rec 2 best_duv (0.002)",    records[2].best_duv)

    -- Same kelvin, different model: new record inserted independently
    local e3={make="A",model="C",kelvin=5600,date="2026-01-01",cct=5600,duv=0.010,cri=88,r9=78}
    append_fixture_record(records,e3)
    assert_equal("3 records total",#records,3)
end

section("sort_fixture_records – ordering")

do
    local records={
        {make="Chroma-Q",model="Space Force",kelvin=5600,date="2026-01-01",cri=nil,r9=nil,duv=nil},
        {make="Aputure", model="600X Pro",   kelvin=5600,date="2026-01-02",cri=nil,r9=nil,duv=nil},
        {make="Aputure", model="300X",       kelvin=5600,date="2026-01-01",cri=nil,r9=nil,duv=nil},
        {make="Aputure", model="600X Pro",   kelvin=3200,date="2026-01-01",cri=nil,r9=nil,duv=nil},
        {make="Aputure", model="600X Pro",   kelvin=5600,date="2026-01-01",cri=nil,r9=nil,duv=nil},
        {make="Arri",    model="SkyPanel S60",kelvin=5600,date="2026-01-01",cri=nil,r9=nil,duv=nil},
    }
    sort_fixture_records(records)
    assert_equal("sort[1].make",   records[1].make,   "Aputure")
    assert_equal("sort[1].model",  records[1].model,  "300X")
    assert_equal("sort[2].model",  records[2].model,  "600X Pro")
    assert_equal("sort[2].kelvin", records[2].kelvin, 3200)
    assert_equal("sort[3].kelvin", records[3].kelvin, 5600)
    -- Within same make/model/kelvin: sorted by date
    assert_equal("sort[3].date",   records[3].date,   "2026-01-01")
    assert_equal("sort[4].date",   records[4].date,   "2026-01-02")
    assert_equal("sort[5].make",   records[5].make,   "Arri")
    assert_equal("sort[6].make",   records[6].make,   "Chroma-Q")
end

section("find_best_for_fixture")

do
    local records={}
    append_fixture_record(records,{make="Aputure",model="600X",kelvin=5600,date="2026-01-01",cct=5572,duv=0.005,cri=90,r9=80})
    append_fixture_record(records,{make="Aputure",model="600X",kelvin=5600,date="2026-01-02",cct=5585,duv=0.002,cri=95,r9=85})
    append_fixture_record(records,{make="Aputure",model="600X",kelvin=3200,date="2026-01-01",cct=3180,duv=0.003,cri=92,r9=82})

    local hist=find_best_for_fixture(records,"Aputure","600X",5600)
    assert_equal("hist: 2 entries for 5600K", #hist.entries, 2)
    assert_equal("hist: best_cri value",      hist.best_cri  and hist.best_cri.cri,   95)
    assert_equal("hist: best_r9 value",       hist.best_r9   and hist.best_r9.r9,     85)
    assert_near ("hist: best_duv value",      hist.best_duv  and hist.best_duv.duv,   0.002, 0.0001)
    assert_equal("hist: best_duv date",       hist.best_duv  and hist.best_duv.date,  "2026-01-02")

    local hist3200=find_best_for_fixture(records,"Aputure","600X",3200)
    assert_equal("hist 3200K: 1 entry",#hist3200.entries,1)

    local histNil=find_best_for_fixture(records,"Unknown","Model",5600)
    assert_equal("no data returns nil",histNil,nil)
end


section("goals_met – session goal boundaries")
do
    local g = { cct=5600, duv=0.000, cri={mode=goals.GOAL_SKIP}, r9={mode=goals.GOAL_SKIP}, tlci={mode=goals.GOAL_SKIP} }
    assert_true("exact targets met", goals.goals_met({cct=5600, duv=0.000, cri=95, r9=80}, g))
    assert_true("CCT +150K pass", goals.goals_met({cct=5750, duv=0.000, cri=95, r9=80}, g))
    assert_true("CCT -150K pass", goals.goals_met({cct=5450, duv=0.000, cri=95, r9=80}, g))
    assert_false("CCT +151K fail", goals.goals_met({cct=5751, duv=0.000, cri=95, r9=80}, g))
    assert_false("CCT -151K fail", goals.goals_met({cct=5449, duv=0.000, cri=95, r9=80}, g))
    assert_true("Duv at tolerance pass", goals.goals_met({cct=5600, duv=0.010, cri=95, r9=80}, g))
    assert_false("Duv over tolerance fail", goals.goals_met({cct=5600, duv=0.011, cri=95, r9=80}, g))
    g.cri = {mode=goals.GOAL_MIN, value=90}
    assert_true("CRI goal met", goals.goals_met({cct=5600, duv=0.000, cri=90, r9=80}, g))
    assert_false("CRI goal below", goals.goals_met({cct=5600, duv=0.000, cri=89, r9=80}, g))
    g.tlci = {mode=goals.GOAL_MIN, value=75}
    assert_true("TLCI nil ignored when missing", goals.goals_met({cct=5600, duv=0.000, cri=95, r9=80, tlci=nil}, g))
end

section("goal_status_str")
do
    assert_equal("GOAL_SKIP empty", goals.goal_status_str(95, {mode=goals.GOAL_SKIP}), "")
    assert_equal("GOAL_MAX maximize", goals.goal_status_str(95, {mode=goals.GOAL_MAX}), "  [maximize]")
    assert_true("GOAL_MIN met contains GOAL MET", goals.goal_status_str(95, {mode=goals.GOAL_MIN, value=90}):find("GOAL MET") ~= nil)
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", PASS, FAIL))
print(string.format("========================================"))

if FAIL > 0 then os.exit(1) end
