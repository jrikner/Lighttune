-- Fixture DB domain tests (shared lua/fixture_db.lua).

local fixture_db = require("fixture_db")

local json_encode_db_record = fixture_db.json_encode_db_record
local json_encode_db_array = fixture_db.json_encode_db_array
local function json_parse_db_array(content)
    return select(1, fixture_db.json_parse_db_array(content))
end
local recompute_best_flags = fixture_db.recompute_best_flags
local append_fixture_record = fixture_db.append_fixture_record
local sort_fixture_records = fixture_db.sort_fixture_records
local find_best_for_fixture = fixture_db.find_best_for_fixture

return function(M)
    M.section("json_encode_db_record / json_parse_db_array – flat schema roundtrip")

    do  -- empty array
        M.assert_equal("empty array",json_encode_db_array({}),"[]")
        M.assert_equal("[] parses to 0 records",#json_parse_db_array("[]"),0)
    end

    do  -- single record with all fields
        local rec={make="Aputure",model="600X Pro",kelvin=5600,date="2026-03-13",contributor="jrikner",
                   cct=5572,duv=0.003,cri=95,r9=88,tlci=91,best_cri=true,best_r9=true,best_tlci=true,best_duv=true}
        local enc=json_encode_db_array({rec})
        local parsed=json_parse_db_array(enc)
        M.assert_equal("count",#parsed,1)
        M.assert_equal("make",parsed[1].make,"Aputure")
        M.assert_equal("model",parsed[1].model,"600X Pro")
        M.assert_equal("kelvin",parsed[1].kelvin,5600)
        M.assert_equal("date",parsed[1].date,"2026-03-13")
        M.assert_equal("contributor",parsed[1].contributor,"jrikner")
        M.assert_equal("cct",parsed[1].cct,5572)
        M.assert_near ("duv",parsed[1].duv,0.003,0.0001)
        M.assert_equal("cri",parsed[1].cri,95)
        M.assert_equal("r9", parsed[1].r9, 88)
        M.assert_equal("tlci",parsed[1].tlci,91)
        M.assert_true ("best_cri flag",  parsed[1].best_cri)
        M.assert_true ("best_r9 flag",   parsed[1].best_r9)
        M.assert_true ("best_tlci flag", parsed[1].best_tlci)
        M.assert_true ("best_duv flag",  parsed[1].best_duv)
    end

    do  -- nil tlci (C-700 measurement)
        local rec={make="Arri",model="SkyPanel",kelvin=3200,date="2026-03-13",contributor="test",
                   cct=3180,duv=-0.001,cri=97,r9=92,tlci=nil}
        local enc=json_encode_db_array({rec})
        local parsed=json_parse_db_array(enc)
        M.assert_equal("nil tlci field",parsed[1].tlci,nil)
        M.assert_equal("cri preserved",  parsed[1].cri,97)
    end

    do  -- negative Duv round-trips correctly
        local rec={make="X",model="Y",kelvin=5600,date="2026-01-01",contributor="t",
                   cct=5580,duv=-0.0123,cri=90,r9=80}
        local parsed=json_parse_db_array(json_encode_db_array({rec}))
        M.assert_near("negative duv roundtrip",parsed[1].duv,-0.0123,0.0001)
    end

    M.section("best_* flags not written when false/nil")

    do
        local rec={make="X",model="Y",kelvin=5600,date="2026-01-01",contributor="t",
                   cct=5580,duv=0.003,cri=90,r9=80,best_cri=nil,best_r9=nil}
        local enc=json_encode_db_record(rec)
        M.assert_false("best_cri absent when nil", enc:find('"best_cri"')~=nil)
    end

    M.section("json_parse_db_array – quote in make/model")
    do
        local rec = {make='Acme "Pro" 600', model="X", kelvin=5600, date="2026-01-01", contributor="t",
                     cct=5580, duv=0.003, cri=90, r9=80}
        local enc = json_encode_db_array({rec})
        local parsed, skipped = fixture_db.json_parse_db_array(enc)
        M.assert_equal("quote make roundtrip count", #parsed, 1)
        M.assert_equal("quote make preserved", parsed[1].make, 'Acme "Pro" 600')
        M.assert_equal("quote skipped", skipped or 0, 0)
    end

    do
        local parsed, skipped = fixture_db.json_parse_db_array('[{broken json}]')
        M.assert_true("malformed block skipped", (skipped or 0) >= 1)
    end

    M.section("recompute_best_flags – correctness")

    do  -- single record: all bests belong to it
        local records={{make="A",model="B",kelvin=5600,cri=90,r9=80,tlci=88,duv=0.003}}
        recompute_best_flags(records)
        M.assert_true ("single: best_cri",  records[1].best_cri)
        M.assert_true ("single: best_r9",   records[1].best_r9)
        M.assert_true ("single: best_tlci", records[1].best_tlci)
        M.assert_true ("single: best_duv",  records[1].best_duv)
    end

    do  -- two records same fixture/kelvin; different metrics win
        local records={
            {make="A",model="B",kelvin=5600,cri=95,r9=75,tlci=nil,duv=0.008},
            {make="A",model="B",kelvin=5600,cri=88,r9=90,tlci=nil,duv=0.002},
        }
        recompute_best_flags(records)
        M.assert_true ("cri winner (rec 1)",  records[1].best_cri)
        M.assert_false("cri loser (rec 2)",   records[2].best_cri)
        M.assert_false("r9 loser (rec 1)",    records[1].best_r9)
        M.assert_true ("r9 winner (rec 2)",   records[2].best_r9)
        M.assert_false("duv loser (rec 1)",   records[1].best_duv)
        M.assert_true ("duv winner (rec 2)",  records[2].best_duv)
    end

    do  -- two fixtures (different models): best flags independent
        local records={
            {make="A",model="M1",kelvin=5600,cri=90,r9=80,duv=0.003},
            {make="A",model="M2",kelvin=5600,cri=85,r9=85,duv=0.001},
        }
        recompute_best_flags(records)
        M.assert_true("M1 best_cri", records[1].best_cri)
        M.assert_true("M2 best_cri", records[2].best_cri)
    end

    do  -- negative Duv: |−0.001| < |+0.005|, so negative value wins
        local records={
            {make="Z",model="Z",kelvin=5600,cri=90,r9=80,duv=0.005},
            {make="Z",model="Z",kelvin=5600,cri=90,r9=80,duv=-0.001},
        }
        recompute_best_flags(records)
        M.assert_false("positive duv not best",  records[1].best_duv)
        M.assert_true ("negative duv is best",   records[2].best_duv)
    end

    M.section("append_fixture_record – never replaces, always appends")

    do
        local records={}
        local e1={make="A",model="B",kelvin=5600,date="2026-01-01",cct=5572,duv=0.005,cri=90,r9=80}
        append_fixture_record(records,e1)
        M.assert_equal("after 1st append: count",#records,1)
        M.assert_equal("after 1st: cri",records[1].cri,90)
        M.assert_true ("after 1st: best_cri set",records[1].best_cri)

        local e2={make="A",model="B",kelvin=5600,date="2026-01-02",cct=5585,duv=0.002,cri=95,r9=85}
        append_fixture_record(records,e2)
        M.assert_equal("after 2nd append: count",#records,2)
        M.assert_equal("first record cri unchanged",records[1].cri,90)
        M.assert_equal("second record cri",records[2].cri,95)
        M.assert_false("rec 1 no longer best_cri",records[1].best_cri)
        M.assert_true ("rec 2 is best_cri",        records[2].best_cri)
        M.assert_false("rec 1 not best_r9 (80<85)", records[1].best_r9)
        M.assert_true ("rec 2 best_r9 (85)",         records[2].best_r9)
        M.assert_true ("rec 2 best_duv (0.002)",    records[2].best_duv)

        local e3={make="A",model="C",kelvin=5600,date="2026-01-01",cct=5600,duv=0.010,cri=88,r9=78}
        append_fixture_record(records,e3)
        M.assert_equal("3 records total",#records,3)
    end

    M.section("sort_fixture_records – ordering")

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
        M.assert_equal("sort[1].make",   records[1].make,   "Aputure")
        M.assert_equal("sort[1].model",  records[1].model,  "300X")
        M.assert_equal("sort[2].model",  records[2].model,  "600X Pro")
        M.assert_equal("sort[2].kelvin", records[2].kelvin, 3200)
        M.assert_equal("sort[3].kelvin", records[3].kelvin, 5600)
        M.assert_equal("sort[3].date",   records[3].date,   "2026-01-01")
        M.assert_equal("sort[4].date",   records[4].date,   "2026-01-02")
        M.assert_equal("sort[5].make",   records[5].make,   "Arri")
        M.assert_equal("sort[6].make",   records[6].make,   "Chroma-Q")
    end

    M.section("find_best_for_fixture")

    do
        local records={}
        append_fixture_record(records,{make="Aputure",model="600X",kelvin=5600,date="2026-01-01",cct=5572,duv=0.005,cri=90,r9=80})
        append_fixture_record(records,{make="Aputure",model="600X",kelvin=5600,date="2026-01-02",cct=5585,duv=0.002,cri=95,r9=85})
        append_fixture_record(records,{make="Aputure",model="600X",kelvin=3200,date="2026-01-01",cct=3180,duv=0.003,cri=92,r9=82})

        local hist=find_best_for_fixture(records,"Aputure","600X",5600)
        M.assert_equal("hist: 2 entries for 5600K", #hist.entries, 2)
        M.assert_equal("hist: best_cri value",      hist.best_cri  and hist.best_cri.cri,   95)
        M.assert_equal("hist: best_r9 value",       hist.best_r9   and hist.best_r9.r9,     85)
        M.assert_near ("hist: best_duv value",      hist.best_duv  and hist.best_duv.duv,   0.002, 0.0001)
        M.assert_equal("hist: best_duv date",       hist.best_duv  and hist.best_duv.date,  "2026-01-02")

        local hist3200=find_best_for_fixture(records,"Aputure","600X",3200)
        M.assert_equal("hist 3200K: 1 entry",#hist3200.entries,1)

        local histNil=find_best_for_fixture(records,"Unknown","Model",5600)
        M.assert_equal("no data returns nil",histNil,nil)
    end

    M.section("golden fixture_db_quote_make.json")
    do
        local fh = io.open("tests/fixtures/fixture_db_quote_make.json", "r")
        M.assert_true("golden fixture file readable", fh ~= nil)
        if fh then
            local content = fh:read("*a")
            fh:close()
            local wrapped = "[" .. content .. "]"
            local parsed, skipped = fixture_db.json_parse_db_array(wrapped)
            M.assert_equal("golden quote count", #parsed, 1)
            M.assert_equal("golden quote make", parsed[1].make, 'Acme "Pro" 600')
            M.assert_equal("golden quote skipped", skipped or 0, 0)
            local enc = json_encode_db_array({parsed[1]})
            local roundtrip, skipped2 = fixture_db.json_parse_db_array(enc)
            M.assert_equal("golden roundtrip make", roundtrip[1].make, 'Acme "Pro" 600')
            M.assert_equal("golden roundtrip skipped", skipped2 or 0, 0)
        end
    end
end
