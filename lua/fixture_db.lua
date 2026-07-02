-- fixture_db.lua — Section 2b fixture database (append-only JSON, best_* flags)
-- Host-testable; no MA3 API. Return-M contract for require/dofile loader.

local M = {}

local function json_unescape_char(n)
    if n == "n" then return "\n"
    elseif n == "r" then return "\r"
    elseif n == "t" then return "\t"
    elseif n == '"' then return '"'
    elseif n == "\\" then return "\\"
    else return n end
end

local function json_get_str(json, key)
    local _, eq = json:find('"'..key..'"%s*:%s*"')
    if not eq then return nil end
    local i = eq + 1
    local buf = {}
    while i <= #json do
        local c = json:sub(i, i)
        if c == "\\" then
            local n = json:sub(i + 1, i + 1)
            if n == "" then return nil end
            buf[#buf + 1] = json_unescape_char(n)
            i = i + 2
        elseif c == '"' then
            return table.concat(buf)
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    return nil
end

local function json_get_num(json, key)
    return tonumber(json:match('"'..key..'"%s*:%s*(-?%d+%.?%d*)'))
end

local function json_get_bool(json, key)
    return json:find('"'..key..'"%s*:%s*true') ~= nil
end

local function json_escape_str(value)
    if value == nil then return "" end
    local s = tostring(value)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    s = s:gsub("[\0-\31]", function(c)
        return string.format("\\u%04x", c:byte())
    end)
    return s
end

local function parse_record_block(block)
    local make   = json_get_str(block, "make")
    local model  = json_get_str(block, "model")
    local kelvin = json_get_num(block, "kelvin")
    if make and model and kelvin then
        return {
            make        = make,
            model       = model,
            kelvin      = kelvin,
            date        = json_get_str(block, "date"),
            contributor = json_get_str(block, "contributor"),
            cct         = json_get_num(block, "cct"),
            duv         = json_get_num(block, "duv"),
            cri         = json_get_num(block, "cri"),
            r9          = json_get_num(block, "r9"),
            tlci        = json_get_num(block, "tlci"),
            best_cri    = json_get_bool(block, "best_cri"),
            best_r9     = json_get_bool(block, "best_r9"),
            best_tlci   = json_get_bool(block, "best_tlci"),
            best_duv    = json_get_bool(block, "best_duv"),
        }
    end
    return nil
end

function M.json_encode_db_record(rec)
    local parts = {}
    local function s(k, v) if v ~= nil then parts[#parts+1] = '"'..k..'":"'..json_escape_str(v)..'"' end end
    local function n(k, v) if v ~= nil then parts[#parts+1] = '"'..k..'":'..tostring(v) end end
    local function f(k, v) if v ~= nil then parts[#parts+1] = '"'..k..'":' ..string.format("%.4f", v) end end
    local function b(k, v) if v       then parts[#parts+1] = '"'..k..'":true' end end

    s("make",        rec.make)
    s("model",       rec.model)
    n("kelvin",      rec.kelvin)
    s("date",        rec.date)
    s("contributor", rec.contributor)
    n("cct",         rec.cct)
    f("duv",         rec.duv)
    n("cri",         rec.cri)
    n("r9",          rec.r9)
    if rec.tlci ~= nil then n("tlci", rec.tlci) end
    b("best_cri",    rec.best_cri)
    b("best_r9",     rec.best_r9)
    b("best_tlci",   rec.best_tlci)
    b("best_duv",    rec.best_duv)
    return "{"..table.concat(parts,",").."}"
end

function M.json_encode_db_array(records)
    if #records == 0 then return "[]" end
    local parts = {}
    for _, rec in ipairs(records) do parts[#parts+1] = M.json_encode_db_record(rec) end
    return "[\n"..table.concat(parts,",\n").."\n]"
end

function M.json_parse_db_array(content)
    local records = {}
    local skipped = 0
    local errors = {}
    if not content or content:match("^%s*%[%s*%]%s*$") then
        return records, skipped, errors
    end
    for block in content:gmatch("%b{}") do
        local rec = parse_record_block(block)
        if rec then
            records[#records+1] = rec
        else
            skipped = skipped + 1
            errors[#errors+1] = "malformed record block"
        end
    end
    return records, skipped, errors
end

function M.recompute_best_flags(records)
    for _, rec in ipairs(records) do
        rec.best_cri = nil; rec.best_r9 = nil; rec.best_tlci = nil; rec.best_duv = nil
    end

    local groups = {}
    for i, rec in ipairs(records) do
        local key = (rec.make or "").."|||"..(rec.model or "").."|||"..tostring(rec.kelvin or 0)
        if not groups[key] then groups[key] = {} end
        groups[key][#groups[key]+1] = i
    end

    for _, idxs in pairs(groups) do
        local bi_cri, bi_r9, bi_tlci, bi_duv = nil, nil, nil, nil
        local bv_cri, bv_r9, bv_tlci, bv_duv = -math.huge, -math.huge, -math.huge, math.huge

        for _, i in ipairs(idxs) do
            local r = records[i]
            if r.cri  and r.cri  > bv_cri  then bv_cri  = r.cri;  bi_cri  = i end
            if r.r9   and r.r9   > bv_r9   then bv_r9   = r.r9;   bi_r9   = i end
            if r.tlci and r.tlci > bv_tlci then bv_tlci = r.tlci; bi_tlci = i end
            if r.duv  ~= nil and math.abs(r.duv) < bv_duv then
                bv_duv = math.abs(r.duv); bi_duv = i
            end
        end

        if bi_cri  then records[bi_cri ].best_cri  = true end
        if bi_r9   then records[bi_r9  ].best_r9   = true end
        if bi_tlci then records[bi_tlci].best_tlci = true end
        if bi_duv  then records[bi_duv ].best_duv  = true end
    end
end

function M.append_fixture_record(records, entry)
    records[#records+1] = {
        make        = entry.make,
        model       = entry.model,
        kelvin      = entry.kelvin,
        date        = entry.date        or os.date("%Y-%m-%d"),
        contributor = entry.contributor or "local",
        cct         = entry.cct,
        duv         = entry.duv,
        cri         = entry.cri,
        r9          = entry.r9,
        tlci        = entry.tlci,
    }
    M.recompute_best_flags(records)
end

function M.sort_fixture_records(records)
    table.sort(records, function(a, b)
        if a.make   ~= b.make   then return a.make   < b.make   end
        if a.model  ~= b.model  then return a.model  < b.model  end
        if a.kelvin ~= b.kelvin then return a.kelvin < b.kelvin end
        return (a.date or "") < (b.date or "")
    end)
end

function M.find_best_for_fixture(records, make, model, kelvin)
    if not make or not model then return nil end
    local result = { entries={}, best_cri=nil, best_r9=nil, best_tlci=nil, best_duv=nil }
    for _, rec in ipairs(records) do
        if rec.make == make and rec.model == model and rec.kelvin == kelvin then
            result.entries[#result.entries+1] = rec
            if rec.best_cri  then result.best_cri  = rec end
            if rec.best_r9   then result.best_r9   = rec end
            if rec.best_tlci then result.best_tlci = rec end
            if rec.best_duv  then result.best_duv  = rec end
        end
    end
    if #result.entries == 0 then return nil end
    return result
end

return M
