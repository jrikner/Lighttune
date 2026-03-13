-- SekonicCalibrator v0.3
-- Lighttune - GrandMA3 Lua Plugin
--
-- Calibrate fixture groups using Sekonic spectromaster measurements.
-- Supported meters: C-700, C-800 (no TLCI), C-7000 (full).
-- Features: session goals, per-group inner loop, session summary, gel hints,
--   TLCI metric, reference group mode, advanced Duv, GDTF capability detection,
--   fixture name from MA3 patch, per-metric fixture database with upsert.

--------------------------------------------------------------------------------
-- SECTION 1: CONSTANTS
--------------------------------------------------------------------------------

local QUALITY = {
    CRI  = { excellent = 95, good = 90, acceptable = 80 },
    R9   = { excellent = 90, good = 80, acceptable = 50 },
    TLCI = { excellent = 90, good = 75, acceptable = 50 },
    DUV  = { excellent = 0.003, good = 0.006, acceptable = 0.010 },
}

local CCT_MIN = 1667
local CCT_MAX = 25000
local DUV_MIN = -0.02
local DUV_MAX =  0.02
local CRI_MIN =  0
local CRI_MAX =  100

-- Goal modes for spectral metrics
local GOAL_MAX  = "max"   -- track and display; no hard floor
local GOAL_MIN  = "min"   -- must reach a specific minimum value
local GOAL_SKIP = "skip"  -- not tracked this session

-- Calibration modes
local MODE_TARGET    = "target"    -- calibrate all groups to a set Kelvin
local MODE_REFERENCE = "reference" -- match all groups to a reference measurement

-- Sekonic meter models
local METER_C700  = "c700"   -- C-700 / C-800: CCT, Duv, CRI, R9 (no TLCI)
local METER_C7000 = "c7000"  -- C-7000: CCT, Duv, CRI, R9, TLCI

-- Gel correction steps: |Duv| threshold → gel amount label
local GEL_STEPS = {
    { threshold = 0.016, amount = "Full" },
    { threshold = 0.010, amount = "1/2"  },
    { threshold = 0.006, amount = "1/4"  },
    { threshold = 0.003, amount = "1/8"  },
}

-- GitHub repo for community fixture data uploads
local GITHUB_REPO = "jrikner/Lighttune-0.1"

--------------------------------------------------------------------------------
-- SECTION 2: COLOR MATH (pure functions, no MA3 API)
--------------------------------------------------------------------------------

-- Convert CCT (Kelvin) to CIE 1931 xy chromaticity.
-- Uses Kang et al. (2002) piecewise cubic approximation.
-- Valid range: 1667K to 25000K.
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

-- Convert CIE 1931 xy to CIE 1976 u'v'.
local function xy_to_uvp(x, y)
    local denom = -2 * x + 12 * y + 3
    if denom == 0 then return 0, 0 end
    return 4 * x / denom, 9 * y / denom
end

-- Convert CIE 1976 u'v' back to CIE 1931 xy.
local function uvp_to_xy(up, vp)
    local denom = 6 * up - 16 * vp + 12
    if denom == 0 then return 0, 0 end
    return 9 * up / denom, 4 * vp / denom
end

-- Apply Duv correction: shift v' (CIE 1976) by the net Duv delta × 1.5.
-- Factor 1.5 converts from CIE 1960 uv to CIE 1976 u'v' scale.
local function apply_duv_correction(x, y, measured_duv, target_duv)
    local up, vp = xy_to_uvp(x, y)
    vp = vp + (target_duv - measured_duv) * 1.5
    return uvp_to_xy(up, vp)
end

-- Compute the target chromaticity for fixture output, plus correction deltas.
local function get_correction(tgt_cct, tgt_duv, meas_cct, meas_duv)
    local tx, ty = cct_to_xy(tgt_cct)
    tx, ty = apply_duv_correction(tx, ty, 0, tgt_duv)
    return {
        target_x  = tx,
        target_y  = ty,
        delta_cct = tgt_cct - meas_cct,
        delta_duv = tgt_duv - meas_duv,
    }
end

-- Convert CIE 1931 xy chromaticity to normalised sRGB (0–1).
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

-- Convert normalised RGB (0–1) to HSB: H (0–360), S (0–1), B (0–1).
local function rgb_to_hsb(r, g, b)
    local max_c = math.max(r, g, b)
    local min_c = math.min(r, g, b)
    local delta = max_c - min_c
    local bri   = max_c
    local s     = (max_c == 0) and 0 or (delta / max_c)
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

-- Rate a quality metric against broadcast thresholds (higher = better).
local function rate_quality(value, thresholds)
    if value >= thresholds.excellent  then return "Excellent"
    elseif value >= thresholds.good   then return "Good"
    elseif value >= thresholds.acceptable then return "Acceptable"
    else return "Poor"
    end
end

-- Rate Duv (inverted: lower absolute value = better).
local function rate_duv(duv)
    local a = math.abs(duv)
    if a <= QUALITY.DUV.excellent    then return "Excellent"
    elseif a <= QUALITY.DUV.good     then return "Good"
    elseif a <= QUALITY.DUV.acceptable then return "Acceptable"
    else return "Poor"
    end
end

-- Return a concise goal-status string for CRI, R9, or TLCI.
local function goal_status_str(measured_val, goal)
    if not goal or goal.mode == GOAL_SKIP then return "" end
    if goal.mode == GOAL_MAX then return "  [maximize]" end
    if measured_val >= goal.value then
        return string.format("  [GOAL MET \xe2\x89\xa5%d]", goal.value)
    else
        return string.format("  [BELOW GOAL – need %d, have %d]", goal.value, measured_val)
    end
end

-- Return a physical gel hint for the measured Duv, or nil if on-target.
-- Positive Duv (green shift) → Minus Green gel.
-- Negative Duv (magenta shift) → Plus Green gel.
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

-- Base64 alphabet (shared by encoder and decoder).
local B64_CHARS  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LOOKUP = {}
for i = 1, #B64_CHARS do B64_LOOKUP[B64_CHARS:sub(i, i)] = i - 1 end

-- Base64 encoder (used for GitHub API uploads). Lua 5.4 bitwise operators.
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

-- Base64 decoder (used for reading GitHub API responses).
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

--------------------------------------------------------------------------------
-- SECTION 2b: FIXTURE DATABASE – JSON HELPERS
--
-- Schema: array of records, one per (make, model, kelvin) triplet.
-- Each metric stores the best measurement ever logged for that fixture/kelvin:
--   { value, params, date, contributor }
-- "Best" = highest for CRI/R9/TLCI; lowest |value| for Duv.
--------------------------------------------------------------------------------

-- Encode a single metric sub-object, or "null" if nil.
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

-- Encode a full DB record.
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

-- Encode a full array of records as a pretty-printed JSON array.
local function json_encode_db_array(records)
    if #records == 0 then return "[]" end
    local parts = {}
    for _, rec in ipairs(records) do
        parts[#parts + 1] = json_encode_db_record(rec)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n]"
end

-- Extract a string value from a JSON fragment: "key":"value"
local function json_get_str(json, key)
    return json:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

-- Extract a number value from a JSON fragment: "key":number
local function json_get_num(json, key)
    return tonumber(json:match('"' .. key .. '"%s*:%s*(-?%d+%.?%d*)'))
end

-- Parse a metric sub-object from within a JSON block.
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

-- Parse a JSON array of DB records produced by json_encode_db_array.
-- Silently ignores malformed blocks.
local function json_parse_db_array(content)
    if not content or content:match("^%s*%[%s*%]%s*$") then return {} end
    local records = {}
    -- %b{} matches each balanced {…} block (handles nested braces correctly)
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

-- Upsert a new measurement into a records array.
-- db_entry: { make, model, kelvin, cri, r9, tlci, duv, cct_measured }
-- Same fixture+kelvin: update a metric only if the new value is better.
-- New kelvin: insert a new record.
local function upsert_fixture_record(records, db_entry, contributor)
    local date       = os.date("%Y-%m-%d")
    contributor      = contributor or "anonymous"
    local params_str = string.format("%dK Duv:%+.4f", db_entry.cct_measured, db_entry.duv)

    local existing = nil
    for _, rec in ipairs(records) do
        if rec.make == db_entry.make
           and rec.model  == db_entry.model
           and rec.kelvin == db_entry.kelvin then
            existing = rec
            break
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
        -- Higher is better for CRI, R9, TLCI
        if db_entry.cri and
           (not existing.cri or db_entry.cri > existing.cri.value) then
            existing.cri = make_metric(db_entry.cri)
        end
        if db_entry.r9 and
           (not existing.r9 or db_entry.r9 > existing.r9.value) then
            existing.r9 = make_metric(db_entry.r9)
        end
        if db_entry.tlci and
           (not existing.tlci or db_entry.tlci > existing.tlci.value) then
            existing.tlci = make_metric(db_entry.tlci)
        end
        -- Lower |duv| is better (closest to on-locus)
        if db_entry.duv and
           (not existing.duv or math.abs(db_entry.duv) < math.abs(existing.duv.value)) then
            existing.duv = make_metric(db_entry.duv)
        end
    end
end

-- Sort records: make A→Z, then model A→Z, then kelvin low→high.
local function sort_fixture_records(records)
    table.sort(records, function(a, b)
        if a.make  ~= b.make  then return a.make  < b.make  end
        if a.model ~= b.model then return a.model < b.model end
        return a.kelvin < b.kelvin
    end)
end

--------------------------------------------------------------------------------
-- SECTION 3: UI HELPERS
--------------------------------------------------------------------------------

-- Display the welcome / intro dialog.
local function show_welcome(display)
    local result = MessageBox({
        title          = "SekonicCalibrator v0.3",
        message        = "Lighttune – GrandMA3 Color Calibration\n\n"
                       .. "Calibrate fixture groups using measurements from\n"
                       .. "your Sekonic spectromaster (C-700, C-800, or C-7000).\n\n"
                       .. "Session goals set once:\n"
                       .. "  • Target Kelvin (or match a reference group)\n"
                       .. "  • CRI / R9 / TLCI goals\n\n"
                       .. "Each group is re-measured until you are happy,\n"
                       .. "then you move on to the next group.\n\n"
                       .. "Fixture measurements are logged locally\n"
                       .. "and optionally uploaded to the community database.",
        display_handle = display,
        buttons        = { "Start", "Cancel" },
    })
    return result == 1
end

-- Prompt for a single numeric parameter with range validation (up to 3 tries).
local function get_number_input(display, title, message, min_val, max_val)
    for attempt = 1, 3 do
        local prefix = attempt > 1
            and string.format("Value must be between %g and %g.\n\n", min_val, max_val)
            or  ""
        local result = MessageBox({
            title          = title,
            message        = prefix .. message,
            display_handle = display,
            input          = true,
            buttons        = { "OK", "Cancel" },
        })
        if result == nil or result == 2 then return nil end
        local num = tonumber(tostring(result))
        if num ~= nil and num >= min_val and num <= max_val then return num end
    end
    return nil
end

-- Prompt for mode + optional minimum for one spectral metric.
local function get_one_spectral_goal(display, metric_name, typical_min)
    local r = MessageBox({
        title          = metric_name .. " Goal",
        message        = string.format(
            "Set the goal for %s.\n\n"
            .. "  As high as possible – track quality, no hard floor\n"
            .. "  Set minimum         – flag groups below a threshold\n"
            .. "  Skip                – not tracking %s this session",
            metric_name, metric_name
        ),
        display_handle = display,
        buttons        = { "As high as possible", "Set minimum", "Skip" },
    })
    if r == nil then return nil end
    if r == 1   then return { mode = GOAL_MAX } end
    if r == 3   then return { mode = GOAL_SKIP } end
    local val = get_number_input(
        display,
        metric_name .. " Minimum",
        string.format(
            "Enter the minimum acceptable %s value.\n"
            .. "Range: %d – %d\n\nBroadcast standard: %d+",
            metric_name, CRI_MIN, CRI_MAX, typical_min
        ),
        CRI_MIN, CRI_MAX
    )
    if not val then return nil end
    return { mode = GOAL_MIN, value = val }
end

-- Prompt for spectral goals (CRI, R9, TLCI) based on a combined selection.
-- meter: METER_C700 or METER_C7000 – TLCI only available on C-7000.
-- Returns { cri, r9, tlci } (each a goal table) or nil on cancel.
local function get_spectral_goals(display, meter)
    local allow_tlci = (meter == METER_C7000)

    local choice
    if allow_tlci then
        choice = MessageBox({
            title          = "Quality Goals",
            message        = "Which colour quality metrics to track?\n\n"
                           .. "  CRI & R9      – general rendering + deep red\n"
                           .. "  All three     – CRI, R9, and TLCI (broadcast camera)\n"
                           .. "  Custom        – choose each metric individually\n"
                           .. "  Skip          – no quality tracking",
            display_handle = display,
            buttons        = { "CRI & R9", "All three", "Custom", "Skip" },
        })
    else
        choice = MessageBox({
            title          = "Quality Goals",
            message        = "Which colour quality metrics to track?\n\n"
                           .. "  CRI & R9      – general rendering + deep red\n"
                           .. "  CRI only      – general colour rendering\n"
                           .. "  R9 only       – deep red rendering\n"
                           .. "  Skip          – no quality tracking\n\n"
                           .. "Note: TLCI requires Sekonic C-7000",
            display_handle = display,
            buttons        = { "CRI & R9", "CRI only", "R9 only", "Skip" },
        })
    end
    if choice == nil then return nil end

    local track_cri, track_r9, track_tlci = false, false, false
    local skip_all = false

    if allow_tlci then
        if     choice == 1 then track_cri = true; track_r9 = true
        elseif choice == 2 then track_cri = true; track_r9 = true; track_tlci = true
        elseif choice == 4 then skip_all = true
        else -- Custom
            local sel = MessageBox({
                title          = "Custom Metrics",
                message        = "Select one metric to track:\n\n"
                               .. "  CRI only   R9 only   TLCI only",
                display_handle = display,
                buttons        = { "CRI only", "R9 only", "TLCI only" },
            })
            if sel == nil then return nil end
            track_cri  = (sel == 1)
            track_r9   = (sel == 2)
            track_tlci = (sel == 3)
        end
    else
        if     choice == 1 then track_cri = true; track_r9 = true
        elseif choice == 2 then track_cri = true
        elseif choice == 3 then track_r9  = true
        else skip_all = true
        end
    end

    if skip_all then
        return {
            cri  = { mode = GOAL_SKIP },
            r9   = { mode = GOAL_SKIP },
            tlci = { mode = GOAL_SKIP },
        }
    end

    local cri_goal  = track_cri  and get_one_spectral_goal(display, "CRI (Ra)", 90) or { mode = GOAL_SKIP }
    if track_cri  and not cri_goal  then return nil end
    local r9_goal   = track_r9   and get_one_spectral_goal(display, "R9",       80) or { mode = GOAL_SKIP }
    if track_r9   and not r9_goal   then return nil end
    local tlci_goal = track_tlci and get_one_spectral_goal(display, "TLCI",     75) or { mode = GOAL_SKIP }
    if track_tlci and not tlci_goal then return nil end

    return { cri = cri_goal, r9 = r9_goal, tlci = tlci_goal }
end

-- Collect reference group CCT and Duv (reference mode only).
local function get_reference_measurements(display, ref_group)
    local cct = get_number_input(
        display,
        "Reference CCT – " .. ref_group,
        string.format(
            "Measure '%s' with your Sekonic meter.\n\n"
            .. "Enter the measured CCT (Kelvin).\nRange: %d – %d",
            ref_group, CCT_MIN, CCT_MAX
        ),
        CCT_MIN, CCT_MAX
    )
    if not cct then return nil end

    local duv = get_number_input(
        display,
        "Reference Duv – " .. ref_group,
        string.format(
            "Enter the measured Duv for '%s'.\nRange: %g to %+g\n\n"
            .. "+value = green  |  -value = magenta",
            ref_group, DUV_MIN, DUV_MAX
        ),
        DUV_MIN, DUV_MAX
    )
    if not duv then return nil end

    return { cct = cct, duv = duv }
end

-- Collect all session goals (called once at the start).
local function get_session_goals(display)
    -- ── Sekonic meter model ───────────────────────────────────────────────
    local meter_choice = MessageBox({
        title          = "Sekonic Meter Model",
        message        = "Which Sekonic meter are you using?\n\n"
                       .. "  C-700 / C-800  – CCT, Duv, CRI, R9  (no TLCI)\n"
                       .. "  C-7000         – CCT, Duv, CRI, R9, TLCI",
        display_handle = display,
        buttons        = { "C-700 / C-800", "C-7000" },
    })
    if meter_choice == nil then return nil end
    local meter = (meter_choice == 1) and METER_C700 or METER_C7000

    -- ── Calibration mode ─────────────────────────────────────────────────
    local mode_choice = MessageBox({
        title          = "Calibration Mode",
        message        = "Choose a calibration mode:\n\n"
                       .. "  Calibrate to target  – set a Kelvin target;\n"
                       .. "                         all groups corrected to it\n\n"
                       .. "  Match to reference   – measure one reference group\n"
                       .. "                         first; all others matched to it",
        display_handle = display,
        buttons        = { "Calibrate to target", "Match to reference" },
    })
    if mode_choice == nil then return nil end

    local cal_mode  = (mode_choice == 1) and MODE_TARGET or MODE_REFERENCE
    local ref_group = nil
    local cct, duv

    if cal_mode == MODE_REFERENCE then
        local rg = nil
        for attempt = 1, 3 do
            local prefix = attempt > 1 and "Please enter a valid name.\n\n" or ""
            local r = MessageBox({
                title          = "Reference Group",
                message        = prefix .. "Enter the name of the reference fixture group\n"
                               .. "(e.g.  Front HMI  |  Key Light  |  1)",
                display_handle = display,
                input          = true,
                buttons        = { "OK", "Cancel" },
            })
            if r == nil or r == 2 then return nil end
            local v = tostring(r):match("^%s*(.-)%s*$")
            if v ~= "" then rg = v; break end
        end
        if not rg then return nil end
        ref_group = rg

        local ref_meas = get_reference_measurements(display, ref_group)
        if not ref_meas then return nil end

        cct = ref_meas.cct
        duv = ref_meas.duv

        MessageBox({
            title          = "Reference Captured",
            message        = string.format(
                "Reference group: %s\n\n"
                .. "  CCT: %dK\n"
                .. "  Duv: %+.4f (%s)\n\n"
                .. "All other groups will be matched to these values.",
                ref_group, cct, duv, rate_duv(duv)
            ),
            display_handle = display,
            buttons        = { "OK" },
        })
    else
        -- ── Target Kelvin ─────────────────────────────────────────────────
        cct = get_number_input(
            display,
            "Target Color Temperature",
            string.format(
                "Enter the target CCT in Kelvin.\nRange: %d – %d\n\n"
                .. "Common values:\n"
                .. "  3200K  Tungsten / Warm\n"
                .. "  4300K  Fluorescent\n"
                .. "  5600K  Daylight\n"
                .. "  6500K  Overcast",
                CCT_MIN, CCT_MAX
            ),
            CCT_MIN, CCT_MAX
        )
        if not cct then return nil end

        -- ── Target Duv (simple or advanced) ──────────────────────────────
        local duv_choice = MessageBox({
            title          = "Target Duv",
            message        = "Target Duv (green-magenta deviation):\n\n"
                           .. "  0.000 (neutral) – standard; on the Planckian locus\n"
                           .. "  Advanced        – set a custom Duv target",
            display_handle = display,
            buttons        = { "0.000 (neutral)", "Advanced" },
        })
        if duv_choice == nil then return nil end

        if duv_choice == 1 then
            duv = 0.000
        else
            duv = get_number_input(
                display,
                "Custom Target Duv",
                string.format(
                    "Enter the target Duv deviation.\nRange: %g to %+g\n\n"
                    .. " 0.000 = on Planckian locus (neutral)\n"
                    .. "+value = green  |  -value = magenta",
                    DUV_MIN, DUV_MAX
                ),
                DUV_MIN, DUV_MAX
            )
            if not duv then return nil end
        end
    end

    -- ── Spectral goals ────────────────────────────────────────────────────
    local spectral = get_spectral_goals(display, meter)
    if not spectral then return nil end

    return {
        meter     = meter,
        mode      = cal_mode,
        ref_group = ref_group,
        cct       = cct,
        duv       = duv,
        cri       = spectral.cri,
        r9        = spectral.r9,
        tlci      = spectral.tlci,
    }
end

-- Prompt for a fixture group name/number.
local function get_group_input(display)
    for attempt = 1, 3 do
        local prefix = attempt > 1 and "Invalid input. Please enter a number or name.\n\n" or ""
        local r = MessageBox({
            title          = "Select Fixture Group",
            message        = prefix .. "Enter the group number or name to calibrate:\n(e.g.  1  or  Front Wash)",
            display_handle = display,
            input          = true,
            buttons        = { "OK", "Cancel" },
        })
        if r == nil or r == 2 then return nil end
        local v = tostring(r):match("^%s*(.-)%s*$")
        if v ~= "" then return v end
    end
    return nil
end

-- Attempt to read fixture manufacturer and model from the MA3 patch for a group.
-- Returns make, model (strings) or nil, nil if unavailable.
local function get_fixture_from_patch(group_name)
    local make, model = nil, nil
    pcall(function()
        local dp = DataPool()
        if not dp then return end
        local groups = dp.Groups
        if not groups then return end

        -- Try numeric access first, then name search
        local grp = nil
        local num = tonumber(group_name)
        if num then
            grp = groups:Child(num - 1)  -- MA3 children are 0-indexed
        end
        if not grp then
            for i = 0, groups:Count() - 1 do
                local g = groups:Child(i)
                if g and g.Name == group_name then
                    grp = g
                    break
                end
            end
        end
        if not grp then return end

        -- Walk group members to find first fixture
        local members = grp.Members
        if not members or members:Count() == 0 then return end
        local fixture = members:Child(0)
        if not fixture then return end

        -- Read fixture type properties
        local ft = fixture.FixtureType
        if not ft then return end

        local m = ft.Manufacturer
        local n = ft.Long or ft.Name
        if m and m ~= "" then make  = m end
        if n and n ~= "" then model = n end
    end)
    return make, model
end

-- Prompt for fixture make and model. Tries patch auto-read first.
-- Returns make, model (strings) or nil, nil if skipped.
local function get_fixture_model_input(display, group_name)
    -- Try to auto-read from MA3 patch
    local patch_make, patch_model = get_fixture_from_patch(group_name)

    if patch_make and patch_model then
        local r = MessageBox({
            title          = "Fixture Identified",
            message        = string.format(
                "Fixture detected from patch:\n\n"
                .. "  Make:  %s\n"
                .. "  Model: %s\n\n"
                .. "Use this for the fixture database?",
                patch_make, patch_model
            ),
            display_handle = display,
            buttons        = { "Yes, use this", "Enter manually", "Skip" },
        })
        if r == nil or r == 3 then return nil, nil end
        if r == 1 then return patch_make, patch_model end
        -- r == 2: fall through to manual entry
    end

    -- Manual entry: make then model
    local make_r = MessageBox({
        title          = "Fixture Make",
        message        = "Enter the fixture manufacturer name.\n"
                       .. "e.g.  Aputure  |  Arri  |  Chroma-Q\n\n"
                       .. "Leave blank to skip fixture logging.",
        display_handle = display,
        input          = true,
        buttons        = { "OK", "Skip" },
    })
    if make_r == nil or make_r == 2 then return nil, nil end
    local make = tostring(make_r):match("^%s*(.-)%s*$")
    if make == "" then return nil, nil end

    local model_r = MessageBox({
        title          = "Fixture Model",
        message        = string.format(
            "Enter the model name for %s.\n"
            .. "e.g.  600X Pro  |  SkyPanel S60-C  |  Space Force",
            make
        ),
        display_handle = display,
        input          = true,
        buttons        = { "OK", "Skip" },
    })
    if model_r == nil or model_r == 2 then return nil, nil end
    local model = tostring(model_r):match("^%s*(.-)%s*$")
    if model == "" then return nil, nil end

    return make, model
end

-- Collect Sekonic measurements for the current attempt.
-- goals is needed to know which meter is in use (TLCI availability).
local function get_measurement_params(display, attempt, goals)
    local suffix     = attempt > 1 and string.format(" (attempt %d)", attempt) or ""
    local track_tlci = goals.tlci and goals.tlci.mode ~= GOAL_SKIP
    local meter_name = (goals.meter == METER_C700) and "C-700/C-800" or "C-7000"

    local cct = get_number_input(
        display, "Measured CCT" .. suffix,
        string.format("CCT reading from Sekonic %s.\nRange: %d – %d K",
            meter_name, CCT_MIN, CCT_MAX),
        CCT_MIN, CCT_MAX
    )
    if not cct then return nil end

    local duv = get_number_input(
        display, "Measured Duv" .. suffix,
        string.format(
            "Duv (\xce\x94uv) reading from Sekonic %s.\nRange: %g to %+g\n\n"
            .. "Shown as 'Deviation' or '\xce\x94uv' on the meter.\n"
            .. "+value = green  |  -value = magenta",
            meter_name, DUV_MIN, DUV_MAX
        ),
        DUV_MIN, DUV_MAX
    )
    if not duv then return nil end

    local cri = get_number_input(
        display, "Measured CRI (Ra)" .. suffix,
        string.format("CRI (Ra) reading from Sekonic %s.\nRange: %d – %d",
            meter_name, CRI_MIN, CRI_MAX),
        CRI_MIN, CRI_MAX
    )
    if not cri then return nil end

    local r9 = get_number_input(
        display, "Measured R9" .. suffix,
        string.format(
            "R9 (deep red) from Sekonic %s.\nRange: %d – %d\n\n"
            .. "Critical for skin tones and costumes on camera.",
            meter_name, CRI_MIN, CRI_MAX
        ),
        CRI_MIN, CRI_MAX
    )
    if not r9 then return nil end

    local tlci = nil
    if track_tlci then
        tlci = get_number_input(
            display, "Measured TLCI" .. suffix,
            string.format(
                "TLCI reading from Sekonic C-7000.\nRange: %d – %d\n\n"
                .. "Television Lighting Consistency Index –\n"
                .. "rates light quality for 3-chip broadcast cameras.\n"
                .. "Broadcast ready: 90+",
                CRI_MIN, CRI_MAX
            ),
            CRI_MIN, CRI_MAX
        )
        if not tlci then return nil end
    end

    return { cct = cct, duv = duv, cri = cri, r9 = r9, tlci = tlci }
end

-- Build a concise goals header line for assessment and summary.
local function goals_summary_line(goals)
    local parts = { string.format("%dK", goals.cct) }

    if goals.duv ~= 0 then
        parts[#parts + 1] = string.format("Duv%+.3f", goals.duv)
    end

    local function metric_str(label, goal)
        if not goal or goal.mode == GOAL_SKIP then return nil end
        if goal.mode == GOAL_MAX then return label .. ":max" end
        return string.format("%s:\xe2\x89\xa5%d", label, goal.value)
    end

    local cri_s  = metric_str("CRI",  goals.cri)
    local r9_s   = metric_str("R9",   goals.r9)
    local tlci_s = metric_str("TLCI", goals.tlci)

    if cri_s  then parts[#parts + 1] = cri_s  end
    if r9_s   then parts[#parts + 1] = r9_s   end
    if tlci_s then parts[#parts + 1] = tlci_s end

    local mode_prefix = ""
    if goals.mode == MODE_REFERENCE then
        mode_prefix = string.format("Ref: %s  |  ", goals.ref_group)
    end

    return mode_prefix .. "Goals: " .. table.concat(parts, "  ")
end

-- Show assessment + correction summary.
-- caps (optional): GDTF capability table { has_tint, has_cto, has_ctb,
--                  has_color_wheel, has_rgb } — enables feature-aware hints.
-- Returns true = apply, false = skip.
local function show_assessment(display, group, goals, measured, correction, attempt, caps)
    local cri_rating  = rate_quality(measured.cri, QUALITY.CRI)
    local r9_rating   = rate_quality(measured.r9,  QUALITY.R9)
    local tlci_rating = measured.tlci and rate_quality(measured.tlci, QUALITY.TLCI) or "n/a"
    local duv_rating  = rate_duv(measured.duv)

    local cri_gs  = goal_status_str(measured.cri,  goals.cri)
    local r9_gs   = goal_status_str(measured.r9,   goals.r9)
    local tlci_gs = measured.tlci and goal_status_str(measured.tlci, goals.tlci) or ""

    -- Warnings
    local warns = {}
    if measured.cri < QUALITY.CRI.acceptable then
        warns[#warns + 1] = "  WARNING: CRI below broadcast minimum (80)"
    end
    if measured.r9 < QUALITY.R9.acceptable then
        warns[#warns + 1] = "  WARNING: R9 below broadcast minimum (50)"
        warns[#warns + 1] = "           Reds may appear dull on camera"
    end
    if measured.tlci and measured.tlci < QUALITY.TLCI.acceptable then
        warns[#warns + 1] = "  WARNING: TLCI below broadcast minimum (50)"
    end
    if math.abs(measured.duv) > QUALITY.DUV.acceptable then
        warns[#warns + 1] = "  WARNING: Strong green/magenta cast (|Duv| > 0.010)"
    end
    local warns_str = #warns > 0 and ("\n" .. table.concat(warns, "\n") .. "\n") or ""

    -- Hints
    local hints = {}

    -- Physical gel (always shown when Duv is off – external correction)
    local gh = gel_hint(measured.duv)
    if gh then hints[#hints + 1] = "  Gel (physical): " .. gh end

    -- Console correction hints – only shown when fixture has the capability
    if caps then
        if caps.has_tint and math.abs(measured.duv) > QUALITY.DUV.good then
            local tint_dir = measured.duv > 0 and "negative (magenta)" or "positive (green)"
            hints[#hints + 1] = string.format(
                "  Tint channel: Fixture has Tint DMX – shift toward %s to correct Duv",
                tint_dir
            )
        end
        local dk = correction.delta_cct
        if math.abs(dk) > 200 then
            if dk < 0 and caps.has_ctb then
                hints[#hints + 1] = "  CTB: Fixture has CTB channel – use to reduce CCT"
            elseif dk > 0 and caps.has_cto then
                hints[#hints + 1] = "  CTO: Fixture has CTO channel – use to raise CCT"
            end
            if caps.has_color_wheel then
                hints[#hints + 1] = "  Color wheel: Check for a CTB/CTO correction slot"
            end
        end
    end

    -- Spectral issues (cannot be fixed via console)
    if measured.cri < 85 then
        hints[#hints + 1] = "  CRI: Cannot be improved via console – try a different"
        hints[#hints + 1] = "       fixture or enable the fixture's high-CRI mode"
    end
    if measured.r9 < 65 then
        hints[#hints + 1] = "  R9:  Low R9 is a spectral issue – consider a high-R9"
        hints[#hints + 1] = "       fixture or add a warming gel"
    end

    local hints_str = #hints > 0
        and ("\n== Hints ==\n\n" .. table.concat(hints, "\n") .. "\n")
        or  ""

    -- Correction deltas
    local dkcct = correction.delta_cct
    local dkduv = correction.delta_duv
    local dkcct_s = dkcct > 0 and string.format("+%dK", dkcct)
                 or dkcct < 0 and string.format("%dK",  dkcct)
                 or "0K (on target)"
    local dkduv_s = dkduv > 0 and string.format("+%.4f", dkduv)
                 or dkduv < 0 and string.format("%.4f",  dkduv)
                 or "0.000 (on target)"

    local tlci_row = measured.tlci
        and string.format("  TLCI     :  %3d  \xe2\x86\x92  %-11s%s\n", measured.tlci, tlci_rating, tlci_gs)
        or  ""

    local msg = string.format(
        "Group: %s  |  Attempt %d\n"
     .. "%s\n\n"
     .. "== Quality ==\n\n"
     .. "  CRI (Ra) :  %3d  \xe2\x86\x92  %-11s%s\n"
     .. "  R9       :  %3d  \xe2\x86\x92  %-11s%s\n"
     .. "%s"
     .. "  Duv      : %+.4f  \xe2\x86\x92  %-11s\n"
     .. "%s\n"
     .. "== Correction ==\n\n"
     .. "  Measured :  %dK  Duv %+.4f\n"
     .. "  Target   :  %dK  Duv %+.4f\n"
     .. "  \xce\x94 Kelvin  :  %s\n"
     .. "  \xce\x94 Duv     :  %s\n"
     .. "%s\n"
     .. "Apply correction to Group %s?",
        group, attempt,
        goals_summary_line(goals),
        measured.cri,  cri_rating,  cri_gs,
        measured.r9,   r9_rating,   r9_gs,
        tlci_row,
        measured.duv, duv_rating,
        warns_str,
        measured.cct, measured.duv,
        goals.cct,    goals.duv,
        dkcct_s, dkduv_s,
        hints_str,
        group
    )

    local result = MessageBox({
        title          = string.format("Assessment – %s (attempt %d)", group, attempt),
        message        = msg,
        display_handle = display,
        buttons        = { "Apply", "Skip" },
    })
    return result == 1
end

-- Show result of a calibration apply.
local function show_result(display, success, group, method, err_msg)
    if success then
        MessageBox({
            title   = "Correction Applied",
            message = string.format(
                "Correction applied to Group %s.\nMethod: %s\n\n"
                .. "Re-measure with Sekonic meter to confirm.",
                group, method
            ),
            display_handle = display,
            buttons        = { "OK" },
        })
    else
        MessageBox({
            title   = "Apply Failed",
            message = string.format(
                "Could not apply correction to Group %s.\n\nError: %s",
                group, tostring(err_msg)
            ),
            display_handle = display,
            buttons        = { "OK" },
        })
    end
end

-- Ask whether the operator is done with the current group.
local function ask_group_done(display, group, attempt)
    local r = MessageBox({
        title   = string.format("Group %s – Done?", group),
        message = string.format(
            "Group: %s  |  Attempt %d\n\n"
            .. "Happy with this group?\n\n"
            .. "  Done          – mark complete and move on\n"
            .. "  Measure Again – re-take a Sekonic reading",
            group, attempt
        ),
        display_handle = display,
        buttons        = { "Done", "Measure Again" },
    })
    return r == 1
end

-- Ask whether to calibrate another group.
local function ask_calibrate_another(display)
    local r = MessageBox({
        title          = "Next Group?",
        message        = "Calibrate another fixture group?",
        display_handle = display,
        buttons        = { "Yes", "No – Finish" },
    })
    return r == 1
end

-- Show end-of-session summary of all calibrated groups.
local function show_session_summary(display, session_log, goals)
    if #session_log == 0 then return end

    local lines = {
        string.format("== Session Summary  (%d group%s) ==\n",
            #session_log, #session_log == 1 and "" or "s"),
        goals_summary_line(goals) .. "\n",
    }

    for _, entry in ipairs(session_log) do
        local m   = entry.measured
        local cor = entry.correction
        local dk  = cor and cor.delta_cct or 0

        local dk_str = dk > 0 and string.format("+%dK", dk)
                    or dk < 0 and string.format("%dK",  dk)
                    or "0K"

        local fails = {}
        local function check(label, val, goal)
            if not goal or goal.mode == GOAL_SKIP then return end
            if goal.mode == GOAL_MIN and val < goal.value then
                fails[#fails + 1] = label
            end
        end
        if m then
            check("CRI",  m.cri,  goals.cri)
            check("R9",   m.r9,   goals.r9)
            if m.tlci then check("TLCI", m.tlci, goals.tlci) end
        end
        local status = #fails == 0 and "OK" or ("Below goal: " .. table.concat(fails, ", "))
        if goals.cri.mode == GOAL_SKIP and goals.r9.mode == GOAL_SKIP
           and goals.tlci.mode == GOAL_SKIP then
            status = "goals skipped"
        end

        local metrics = ""
        if m then
            metrics = string.format("CRI:%d  R9:%d", m.cri, m.r9)
            if m.tlci then metrics = metrics .. string.format("  TLCI:%d", m.tlci) end
            metrics = metrics .. string.format("  Duv:%+.3f", m.duv)
        end

        local fix_str = ""
        if entry.make and entry.model then
            fix_str = string.format(" [%s %s]", entry.make, entry.model)
        end

        lines[#lines + 1] = string.format(
            "\nGroup: %s%s\n  %s  \xce\x94K:%s  (%d attempt%s)\n  Status: %s",
            entry.group, fix_str,
            metrics, dk_str,
            entry.attempt, entry.attempt == 1 and "" or "s",
            status
        )
    end

    MessageBox({
        title          = "Session Complete",
        message        = table.concat(lines, "\n"),
        display_handle = display,
        buttons        = { "OK" },
    })
end

--------------------------------------------------------------------------------
-- SECTION 3b: GDTF CAPABILITY DETECTION
--------------------------------------------------------------------------------

-- Platform constants (forward-declared here for GDTF helpers)
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local NULL_DEV   = IS_WINDOWS and "NUL" or "/dev/null"
local TMP_DIR    = IS_WINDOWS
    and (os.getenv("TEMP") or "C:\\Temp")
    or  "/tmp"

-- Return the GrandMA3 GDTF library directory.
local function get_gdtf_dir()
    local sep = IS_WINDOWS and "\\" or "/"
    if IS_WINDOWS then
        local base = os.getenv("PROGRAMDATA") or "C:\\ProgramData"
        return base .. sep .. "MALightingTechnology" .. sep .. "gma3_library" .. sep .. "gdtf"
    else
        local base = os.getenv("HOME") or "/root"
        return base .. sep .. "MALightingTechnology" .. sep .. "gma3_library" .. sep .. "gdtf"
    end
end

-- Locate a GDTF file for a given fixture make + model.
-- Returns absolute path or nil if not found.
local function find_gdtf_file(make, model)
    if not make or not model or make == "" or model == "" then return nil end
    local dir    = get_gdtf_dir()
    local prefix = (make .. "@" .. model):gsub("[%.%+%^%$%(%)%[%]%%]", "%%%1")
    local found  = nil
    pcall(function()
        local cmd
        if IS_WINDOWS then
            cmd = string.format(
                'dir /b "%s" 2>NUL | findstr /i /b "%s@"',
                dir, make .. "@" .. model
            )
        else
            cmd = string.format(
                'ls "%s" 2>/dev/null | grep -i "^%s@" | head -1',
                dir, prefix
            )
        end
        local h = io.popen(cmd)
        if h then
            local line = h:read("*l")
            h:close()
            if line and line ~= "" then
                local fname = line:match("^%s*(.-)%s*$")
                found = dir .. (IS_WINDOWS and "\\" or "/") .. fname
            end
        end
    end)
    return found
end

-- Read GDTF description.xml from a fixture's GDTF archive and return
-- a capability table, or nil if the GDTF file cannot be read.
local function read_gdtf_capabilities(make, model)
    local gdtf_path = find_gdtf_file(make, model)
    if not gdtf_path then return nil end

    local xml = nil
    pcall(function()
        -- GDTF files are ZIP archives; unzip -p extracts to stdout
        local cmd = string.format('unzip -p "%s" description.xml 2>%s', gdtf_path, NULL_DEV)
        local h = io.popen(cmd)
        if h then
            xml = h:read("*a")
            h:close()
        end
    end)
    if not xml or xml == "" then return nil end

    return {
        -- Colour-control attributes present in the fixture
        has_tint        = xml:find('Name="Tint"')          ~= nil,
        has_cto         = xml:find('Name="CTO"')           ~= nil,
        has_ctb         = xml:find('Name="CTB"')           ~= nil,
        has_rgb         = xml:find('Name="ColorAdd_R"')    ~= nil,
        has_color_wheel = xml:find('<Wheel[^>]*Name="[Cc]olor"') ~= nil,
        -- Manufacturer-rated CRI if declared in GDTF
        gdtf_cri        = tonumber(xml:match('CRI="(%d+)"')),
    }
end

--------------------------------------------------------------------------------
-- SECTION 4: FIXTURE APPLICATION
--------------------------------------------------------------------------------

local function select_group(group)
    local ok, err = pcall(function() Cmd('Group "' .. tostring(group) .. '"') end)
    if not ok then
        local ok2, err2 = pcall(function() Cmd("Group " .. tostring(group)) end)
        if not ok2 then return false, tostring(err2) end
    end
    return true, nil
end

local function apply_color_xyY(x, y)
    local ok, err = pcall(function()
        SetColor("xyY", x, y, 1.0, 1.0, 1.0, false)
    end)
    if not ok then return false, tostring(err) end
    return true, nil
end

local function apply_color_hsb(x, y)
    local r, g, b = xy_to_rgb(x, y)
    local h, s, _ = rgb_to_hsb(r, g, b)
    local ok, err = pcall(function()
        SetColor("HSB", h, s, 1.0, 1.0, 1.0, false)
    end)
    if not ok then return false, tostring(err) end
    return true, nil
end

local function calibrate_group(group, x, y)
    local sel_ok, sel_err = select_group(group)
    if not sel_ok then
        return { success = false, method = "none", error_msg = sel_err }
    end
    local xy_ok, xy_err = apply_color_xyY(x, y)
    if xy_ok then
        return { success = true, method = "xyY (precision)", error_msg = nil }
    end
    local hsb_ok, hsb_err = apply_color_hsb(x, y)
    if hsb_ok then
        return { success = true, method = "HSB (approx)", error_msg = nil }
    end
    return {
        success   = false,
        method    = "none",
        error_msg = string.format("xyY: %s | HSB: %s", xy_err, hsb_err),
    }
end

--------------------------------------------------------------------------------
-- SECTION 5: DATA LOGGING (local file + optional GitHub community upload)
--------------------------------------------------------------------------------

-- Resolve the plugin's root directory.
local function get_data_dir()
    local sep  = IS_WINDOWS and "\\" or "/"
    local base
    if IS_WINDOWS then
        base = (os.getenv("APPDATA") or (os.getenv("USERPROFILE") .. "\\AppData\\Roaming"))
             .. "\\MALightingTechnology\\gma3_library\\datapools\\plugins\\SekonicCalibrator"
    else
        base = (os.getenv("HOME") or "/root")
             .. "/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator"
    end
    return base
end

local function mkdir_p(path)
    if IS_WINDOWS then
        os.execute('mkdir "' .. path .. '" 2>' .. NULL_DEV)
    else
        os.execute('mkdir -p "' .. path .. '" 2>' .. NULL_DEV)
    end
end

-- Read config.json for GitHub token and username.
-- Returns { github_token, github_username } or nil.
local function load_config()
    local sep  = IS_WINDOWS and "\\" or "/"
    local path = get_data_dir() .. sep .. "config.json"
    local f    = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local token    = content:match('"github_token"%s*:%s*"([^"]+)"')
    local username = content:match('"github_username"%s*:%s*"([^"]+)"')
    if not token or token == "" then return nil end
    return { github_token = token, github_username = username }
end

-- Save/upsert the fixture db_entry into the local fixture_log.json.
-- db_entry: { make, model, kelvin, cri, r9, tlci, duv, cct_measured }
local function save_fixture_log_local(db_entry, config)
    local ok = pcall(function()
        local sep  = IS_WINDOWS and "\\" or "/"
        local dir  = get_data_dir() .. sep .. "data"
        mkdir_p(dir)
        local path = dir .. sep .. "fixture_log.json"

        local records = {}
        local rf = io.open(path, "r")
        if rf then
            records = json_parse_db_array(rf:read("*a"))
            rf:close()
        end

        upsert_fixture_record(records, db_entry, config and config.github_username)
        sort_fixture_records(records)

        local wf = io.open(path, "w")
        if wf then
            wf:write(json_encode_db_array(records))
            wf:close()
        end
    end)
    return ok
end

-- Execute a curl command and return its stdout, or nil on error.
local function curl_exec(cmd)
    local ok, result = pcall(function()
        local h = io.popen(cmd)
        if not h then return nil end
        local out = h:read("*a")
        h:close()
        return out
    end)
    return ok and result or nil
end

-- Upload db_entry to the per-user community file in the GitHub repository.
-- File path: data/community/{username}.json
-- Uses GET → upsert → sort → PUT pattern so updates are additive.
-- Silent on any failure.
local function upload_community_file(db_entry, config)
    if not config or not config.github_token or not config.github_username then return false end

    -- Quick connectivity check (3 s timeout)
    local check_cmd = string.format(
        'curl -s --max-time 3 -o %s -w "%%{http_code}" https://api.github.com 2>%s',
        NULL_DEV, NULL_DEV
    )
    local code = curl_exec(check_cmd)
    if not code or not code:match("^2%d%d") then return false end

    local username = config.github_username
    local filepath = "data/community/" .. username .. ".json"
    local url      = string.format(
        "https://api.github.com/repos/%s/contents/%s",
        GITHUB_REPO, filepath
    )
    local auth_hdr = '-H "Authorization: token ' .. config.github_token .. '"'

    -- GET existing file to obtain current content + SHA
    local get_cmd = string.format(
        'curl -s %s -H "Accept: application/vnd.github.v3+json" "%s" 2>%s',
        auth_hdr, url, NULL_DEV
    )
    local get_resp = curl_exec(get_cmd)
    local sha      = get_resp and get_resp:match('"sha"%s*:%s*"([^"]+)"') or nil
    local records  = {}

    if get_resp then
        local b64 = get_resp:match('"content"%s*:%s*"([A-Za-z0-9%+%/%=\n\\]+)"')
        if b64 then
            b64 = b64:gsub("\\n", ""):gsub("%s", "")
            local content = pcall(base64_decode, b64) and base64_decode(b64) or nil
            if content and content ~= "" then
                records = json_parse_db_array(content)
            end
        end
    end

    -- Upsert and sort
    upsert_fixture_record(records, db_entry, username)
    sort_fixture_records(records)

    -- Encode new content
    local new_json    = json_encode_db_array(records)
    local b64_content = base64_encode(new_json)

    -- Build PUT body via temp file (avoids shell quoting issues)
    local tmp = TMP_DIR .. (IS_WINDOWS and "\\" or "/") .. "sc_community.json"
    local tf  = io.open(tmp, "w")
    if not tf then return false end

    local commit_msg = string.format(
        "Update fixture data: %s %s @ %dK",
        (db_entry.make  or ""):gsub('"', '\\"'),
        (db_entry.model or ""):gsub('"', '\\"'),
        db_entry.kelvin or 0
    )
    if sha then
        tf:write(string.format(
            '{"message":"%s","content":"%s","sha":"%s"}',
            commit_msg, b64_content, sha
        ))
    else
        tf:write(string.format(
            '{"message":"%s","content":"%s"}',
            commit_msg, b64_content
        ))
    end
    tf:close()

    local put_cmd = string.format(
        'curl -s -X PUT %s -H "Content-Type: application/json" '
        .. '-d @"%s" -o %s -w "%%{http_code}" "%s" 2>%s',
        auth_hdr, tmp, NULL_DEV, url, NULL_DEV
    )
    local resp = curl_exec(put_cmd)
    return resp and (resp == "200" or resp == "201")
end

-- Orchestrate local save and optional community upload. Never interrupts calibration.
local function log_fixture_data(display, db_entry, config)
    if not db_entry.make or not db_entry.model then return end

    save_fixture_log_local(db_entry, config)

    if config and config.github_token and config.github_username then
        pcall(upload_community_file, db_entry, config)
    elseif config and config.github_token and not config.github_username then
        -- Token present but no username configured
        local sep      = IS_WINDOWS and "\\" or "/"
        local flag_dir = get_data_dir() .. sep .. "data"
        mkdir_p(flag_dir)
        local flag_path = flag_dir .. sep .. ".username_hint_shown"
        local flag = io.open(flag_path, "r")
        if not flag then
            local wf = io.open(flag_path, "w")
            if wf then wf:write("1"); wf:close() end
            MessageBox({
                title          = "Community Upload",
                message        = "GitHub token found but no username set.\n\n"
                               .. "Add to SekonicCalibrator/data/config.json:\n\n"
                               .. '  "github_username": "your_github_username"\n\n'
                               .. "This is needed to upload to the community database.",
                display_handle = display,
                buttons        = { "OK" },
            })
        else
            flag:close()
        end
    elseif not config then
        -- No config at all – show one-time hint
        local sep      = IS_WINDOWS and "\\" or "/"
        local flag_dir = get_data_dir() .. sep .. "data"
        mkdir_p(flag_dir)
        local flag_path = flag_dir .. sep .. ".upload_hint_shown"
        local flag = io.open(flag_path, "r")
        if not flag then
            local wf = io.open(flag_path, "w")
            if wf then wf:write("1"); wf:close() end
            MessageBox({
                title          = "Community Upload",
                message        = "Fixture measurements are saved locally.\n\n"
                               .. "To share with the community database, create\n"
                               .. "SekonicCalibrator/data/config.json:\n\n"
                               .. '  {\n'
                               .. '    "github_token":    "ghp_...",\n'
                               .. '    "github_username": "your_username"\n'
                               .. '  }\n\n'
                               .. "See README for details.",
                display_handle = display,
                buttons        = { "OK" },
            })
        else
            flag:close()
        end
    end
end

--------------------------------------------------------------------------------
-- SECTION 6: MAIN ENTRY POINT
--------------------------------------------------------------------------------

local function main(display, ...)
    local ok, err = pcall(function()

        if not show_welcome(display) then return end

        local goals = get_session_goals(display)
        if not goals then return end

        local config      = load_config()
        local session_log = {}

        -- ── Outer loop: group by group ──────────────────────────────────────
        repeat
            local group = get_group_input(display)
            if not group then break end

            -- Get fixture make/model (patch auto-read → manual fallback)
            local fixture_make, fixture_model = get_fixture_model_input(display, group)

            -- Read GDTF capabilities for feature-aware hints (nil = no data)
            local caps = read_gdtf_capabilities(fixture_make, fixture_model)

            local attempt         = 0
            local last_measured   = nil
            local last_correction = nil
            local applied_once    = false

            -- ── Inner loop: re-measure same group until happy ───────────────
            repeat
                attempt = attempt + 1

                local measured = get_measurement_params(display, attempt, goals)
                if not measured then break end

                last_measured = measured

                local correction = get_correction(
                    goals.cct, goals.duv,
                    measured.cct, measured.duv
                )
                last_correction = correction

                local apply = show_assessment(
                    display, group, goals, measured, correction, attempt, caps
                )

                if apply then
                    local result = calibrate_group(
                        group, correction.target_x, correction.target_y
                    )
                    show_result(
                        display, result.success, group,
                        result.method, result.error_msg
                    )
                    if result.success then applied_once = true end
                end

            until ask_group_done(display, group, attempt)
            -- ─────────────────────────────────────────────────────────────────

            -- Log fixture data (local + optional community upload)
            if last_measured then
                local db_entry = {
                    make         = fixture_make,
                    model        = fixture_model,
                    kelvin       = goals.cct,
                    cri          = last_measured.cri,
                    r9           = last_measured.r9,
                    tlci         = last_measured.tlci,
                    duv          = last_measured.duv,
                    cct_measured = last_measured.cct,
                }
                log_fixture_data(display, db_entry, config)

                table.insert(session_log, {
                    group      = group,
                    make       = fixture_make,
                    model      = fixture_model,
                    measured   = last_measured,
                    correction = last_correction,
                    applied    = applied_once,
                    attempt    = attempt,
                })
            end

        until not ask_calibrate_another(display)
        -- ────────────────────────────────────────────────────────────────────

        show_session_summary(display, session_log, goals)

    end)

    if not ok then
        MessageBox({
            title          = "Unexpected Error",
            message        = "An unexpected error occurred:\n\n" .. tostring(err)
                           .. "\n\nPlease report this to the Lighttune project.",
            display_handle = display,
            buttons        = { "OK" },
        })
    end
end

return main
