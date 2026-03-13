-- test_color_math.lua
-- Standalone Lua 5.4 unit tests for SekonicCalibrator color math functions.
-- Run with: lua test_color_math.lua
--
-- Tests exercise pure color math logic and DB helpers independently of MA3 API.

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

--------------------------------------------------------------------------------
-- Inline copies (mirrors SekonicCalibrator.lua, sections 2 and 2b)
--------------------------------------------------------------------------------

local CCT_MIN = 1667
local CCT_MAX = 25000

local function cct_to_xy(T)
    T = math.max(CCT_MIN, math.min(CCT_MAX, T))
    local x, y
    if T <= 4000 then
        x = (-0.2661239e9/T^3)+(-0.2343580e6/T^2)+(0.8776956e3/T)+0.179910
        y = (-1.1063814*x^3)+(-1.34811020*x^2)+(2.18555832*x)-0.20219683
    else
        x = (-3.0258469e9/T^3)+(2.1070379e6/T^2)+(0.2226347e3/T)+0.240390
        y = (3.0817580*x^3)+(-5.87338670*x^2)+(3.75112997*x)-0.37001483
    end
    return x, y
end

local function xy_to_uvp(x, y)
    local denom = -2*x+12*y+3; if denom==0 then return 0,0 end
    return 4*x/denom, 9*y/denom
end

local function uvp_to_xy(up, vp)
    local denom = 6*up-16*vp+12; if denom==0 then return 0,0 end
    return 9*up/denom, 4*vp/denom
end

local function apply_duv_correction(x,y,measured_duv,target_duv)
    local up,vp=xy_to_uvp(x,y); vp=vp+(target_duv-measured_duv)*1.5
    return uvp_to_xy(up,vp)
end

local function xy_to_rgb(x,y)
    if y==0 then y=0.0001 end
    local X=x/y; local Y=1.0; local Z=(1-x-y)/y
    local r=3.2404542*X-1.5371385*Y-0.4985314*Z
    local g=-0.9692660*X+1.8760108*Y+0.0415560*Z
    local b=0.0556434*X-0.2040259*Y+1.0572252*Z
    r=math.max(0,r); g=math.max(0,g); b=math.max(0,b)
    local mc=math.max(r,g,b)
    if mc>0 then r=r/mc; g=g/mc; b=b/mc end
    return r^(1/2.2), g^(1/2.2), b^(1/2.2)
end

local function rgb_to_hsb(r,g,b)
    local mc=math.max(r,g,b); local mn=math.min(r,g,b); local d=mc-mn
    local bri=mc; local s=(mc==0) and 0 or d/mc
    local h
    if d==0 then h=0
    elseif mc==r then h=60*(((g-b)/d)%6)
    elseif mc==g then h=60*(((b-r)/d)+2)
    else h=60*(((r-g)/d)+4) end
    if h<0 then h=h+360 end
    return h,s,bri
end

local QUALITY = {
    CRI  = { excellent=95, good=90, acceptable=80 },
    R9   = { excellent=90, good=80, acceptable=50 },
    TLCI = { excellent=90, good=75, acceptable=50 },
    DUV  = { excellent=0.003, good=0.006, acceptable=0.010 },
}

local GEL_STEPS = {
    { threshold=0.016, amount="Full" },
    { threshold=0.010, amount="1/2"  },
    { threshold=0.006, amount="1/4"  },
    { threshold=0.003, amount="1/8"  },
}

local function gel_hint(duv)
    local abs_duv=math.abs(duv); local amount=nil
    for _,step in ipairs(GEL_STEPS) do
        if abs_duv>step.threshold then amount=step.amount; break end
    end
    if not amount then return nil end
    if duv>0 then return string.format("%s Minus Green  (Duv %+.4f, green shift)",  amount,duv)
    else          return string.format("%s Plus Green   (Duv %+.4f, magenta shift)", amount,duv) end
end

local B64_CHARS  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LOOKUP = {}
for i=1,#B64_CHARS do B64_LOOKUP[B64_CHARS:sub(i,i)]=i-1 end

local function base64_encode(data)
    local result={}
    for i=1,#data,3 do
        local a=data:byte(i) or 0; local b=data:byte(i+1) or 0; local c=data:byte(i+2) or 0
        local n=(a<<16)|(b<<8)|c
        result[#result+1]=B64_CHARS:sub(((n>>18)&63)+1,((n>>18)&63)+1)
        result[#result+1]=B64_CHARS:sub(((n>>12)&63)+1,((n>>12)&63)+1)
        result[#result+1]=B64_CHARS:sub(((n>>6) &63)+1,((n>>6) &63)+1)
        result[#result+1]=B64_CHARS:sub(( n      &63)+1,( n     &63)+1)
    end
    local encoded=table.concat(result); local pad=(3-#data%3)%3
    return encoded:sub(1,#encoded-pad)..("="):rep(pad)
end

local function base64_decode(data)
    data=data:gsub("[^%w%+%/%=]",""); local result={}
    for i=1,#data,4 do
        local a=B64_LOOKUP[data:sub(i,  i  )] or 0
        local b=B64_LOOKUP[data:sub(i+1,i+1)] or 0
        local c=B64_LOOKUP[data:sub(i+2,i+2)] or 0
        local d=B64_LOOKUP[data:sub(i+3,i+3)] or 0
        local n=(a<<18)|(b<<12)|(c<<6)|d
        result[#result+1]=string.char((n>>16)&0xFF)
        if data:sub(i+2,i+2)~="=" then result[#result+1]=string.char((n>>8)&0xFF) end
        if data:sub(i+3,i+3)~="=" then result[#result+1]=string.char( n    &0xFF) end
    end
    return table.concat(result)
end

local function rate_quality(value,thresholds)
    if value>=thresholds.excellent   then return "Excellent"
    elseif value>=thresholds.good    then return "Good"
    elseif value>=thresholds.acceptable then return "Acceptable"
    else return "Poor" end
end

local function rate_duv(duv)
    local a=math.abs(duv)
    if a<=QUALITY.DUV.excellent     then return "Excellent"
    elseif a<=QUALITY.DUV.good      then return "Good"
    elseif a<=QUALITY.DUV.acceptable then return "Acceptable"
    else return "Poor" end
end

-- ── DB helpers (mirrors Section 2b) ──────────────────────────────────────────

local function json_get_str(json,key)  return json:match('"'..key..'"%s*:%s*"([^"]*)"') end
local function json_get_num(json,key)  return tonumber(json:match('"'..key..'"%s*:%s*(-?%d+%.?%d*)')) end
local function json_get_bool(json,key) return json:find('"'..key..'"%s*:%s*true') ~= nil end

local function json_encode_db_record(rec)
    local parts={}
    local function s(k,v) if v~=nil then parts[#parts+1]='"'..k..'":"'..tostring(v):gsub('"','\\"')..'"' end end
    local function n(k,v) if v~=nil then parts[#parts+1]='"'..k..'":'..tostring(v) end end
    local function f(k,v) if v~=nil then parts[#parts+1]='"'..k..'":' ..string.format("%.4f",v) end end
    local function b(k,v) if v       then parts[#parts+1]='"'..k..'":true' end end
    s("make",rec.make); s("model",rec.model); n("kelvin",rec.kelvin)
    s("date",rec.date); s("contributor",rec.contributor)
    n("cct",rec.cct); f("duv",rec.duv); n("cri",rec.cri); n("r9",rec.r9)
    if rec.tlci~=nil then n("tlci",rec.tlci) end
    b("best_cri",rec.best_cri); b("best_r9",rec.best_r9)
    b("best_tlci",rec.best_tlci); b("best_duv",rec.best_duv)
    return "{"..table.concat(parts,",").."}"
end

local function json_encode_db_array(records)
    if #records==0 then return "[]" end
    local parts={}
    for _,rec in ipairs(records) do parts[#parts+1]=json_encode_db_record(rec) end
    return "[\n"..table.concat(parts,",\n").."\n]"
end

local function json_parse_db_array(content)
    if not content or content:match("^%s*%[%s*%]%s*$") then return {} end
    local records={}
    for block in content:gmatch("%b{}") do
        local make=json_get_str(block,"make"); local model=json_get_str(block,"model")
        local kelvin=json_get_num(block,"kelvin")
        if make and model and kelvin then
            records[#records+1]={
                make=make, model=model, kelvin=kelvin,
                date=json_get_str(block,"date"),
                contributor=json_get_str(block,"contributor"),
                cct=json_get_num(block,"cct"),
                duv=json_get_num(block,"duv"),
                cri=json_get_num(block,"cri"), r9=json_get_num(block,"r9"),
                tlci=json_get_num(block,"tlci"),
                best_cri=json_get_bool(block,"best_cri"),
                best_r9=json_get_bool(block,"best_r9"),
                best_tlci=json_get_bool(block,"best_tlci"),
                best_duv=json_get_bool(block,"best_duv"),
            }
        end
    end
    return records
end

local function recompute_best_flags(records)
    for _,rec in ipairs(records) do
        rec.best_cri=nil; rec.best_r9=nil; rec.best_tlci=nil; rec.best_duv=nil
    end
    local groups={}
    for i,rec in ipairs(records) do
        local key=(rec.make or "").."|||"..(rec.model or "").."|||"..tostring(rec.kelvin or 0)
        if not groups[key] then groups[key]={} end
        groups[key][#groups[key]+1]=i
    end
    for _,idxs in pairs(groups) do
        local bi_cri,bi_r9,bi_tlci,bi_duv=nil,nil,nil,nil
        local bv_cri,bv_r9,bv_tlci,bv_duv=-math.huge,-math.huge,-math.huge,math.huge
        for _,i in ipairs(idxs) do
            local r=records[i]
            if r.cri  and r.cri  >bv_cri  then bv_cri=r.cri;   bi_cri=i  end
            if r.r9   and r.r9   >bv_r9   then bv_r9=r.r9;     bi_r9=i   end
            if r.tlci and r.tlci >bv_tlci then bv_tlci=r.tlci;  bi_tlci=i end
            if r.duv~=nil and math.abs(r.duv)<bv_duv then bv_duv=math.abs(r.duv); bi_duv=i end
        end
        if bi_cri  then records[bi_cri ].best_cri =true end
        if bi_r9   then records[bi_r9  ].best_r9  =true end
        if bi_tlci then records[bi_tlci].best_tlci=true end
        if bi_duv  then records[bi_duv ].best_duv =true end
    end
end

local function append_fixture_record(records,entry)
    records[#records+1]={
        make=entry.make, model=entry.model, kelvin=entry.kelvin,
        date=entry.date or "2026-01-01",
        contributor=entry.contributor or "local",
        cct=entry.cct, duv=entry.duv, cri=entry.cri, r9=entry.r9, tlci=entry.tlci,
    }
    recompute_best_flags(records)
end

local function sort_fixture_records(records)
    table.sort(records, function(a,b)
        if a.make  ~=b.make   then return a.make  <b.make   end
        if a.model ~=b.model  then return a.model <b.model  end
        if a.kelvin~=b.kelvin then return a.kelvin<b.kelvin end
        return (a.date or "")<(b.date or "")
    end)
end

local function find_best_for_fixture(records,make,model,kelvin)
    if not make or not model then return nil end
    local result={entries={},best_cri=nil,best_r9=nil,best_tlci=nil,best_duv=nil}
    for _,rec in ipairs(records) do
        if rec.make==make and rec.model==model and rec.kelvin==kelvin then
            result.entries[#result.entries+1]=rec
            if rec.best_cri  then result.best_cri=rec  end
            if rec.best_r9   then result.best_r9=rec   end
            if rec.best_tlci then result.best_tlci=rec end
            if rec.best_duv  then result.best_duv=rec  end
        end
    end
    if #result.entries==0 then return nil end
    return result
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

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

section("base64_encode – RFC 4648 vectors")
assert_equal("encode ''",      base64_encode(""),"")
assert_equal("encode 'f'",     base64_encode("f"),"Zg==")
assert_equal("encode 'fo'",    base64_encode("fo"),"Zm8=")
assert_equal("encode 'foo'",   base64_encode("foo"),"Zm9v")
assert_equal("encode 'foobar'",base64_encode("foobar"),"Zm9vYmFy")

section("base64_decode – roundtrip")
assert_equal("decode ''",        base64_decode(""),"")
assert_equal("decode 'Zg=='",    base64_decode("Zg=="),"f")
assert_equal("decode 'Zm9v'",    base64_decode("Zm9v"),"foo")
assert_equal("decode 'Zm9vYmFy'",base64_decode("Zm9vYmFy"),"foobar")
do
    local orig="Hello, world! 1234 \x00\xFF"
    assert_equal("encode/decode roundtrip",base64_decode(base64_encode(orig)),orig)
end

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

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", PASS, FAIL))
print(string.format("========================================"))

if FAIL > 0 then os.exit(1) end
