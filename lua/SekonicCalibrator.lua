-- SekonicCalibrator v0.2
-- Lighttune - GrandMA3 Lua Plugin
--
-- Calibrate fixture groups using Sekonic C-7000 spectromaster measurements.
-- Features: session goals, per-group inner loop, session summary, gel hints,
--   TLCI metric, reference group mode, advanced Duv, fixture data logging.

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

-- Gel correction steps: |Duv| threshold → gel amount label
-- Industry-standard green/magenta correction filter guide
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
    -- GOAL_MIN
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

-- Base64 encoder (used for GitHub API uploads). Lua 5.4 bitwise operators.
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
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

-- Minimal JSON encoder for a flat key-value entry table.
local function json_encode_entry(entry)
    local order = {
        "date", "fixture", "group",
        "cct_measured", "duv_measured", "cri", "r9", "tlci",
        "cct_target", "duv_target", "attempts",
    }
    local parts = {}
    for _, k in ipairs(order) do
        local v = entry[k]
        local kstr = '"' .. k .. '"'
        if type(v) == "string" then
            parts[#parts + 1] = kstr .. ':"' .. v:gsub('"', '\\"') .. '"'
        elseif type(v) == "number" then
            parts[#parts + 1] = kstr .. ":" .. tostring(v)
        elseif v == nil then
            parts[#parts + 1] = kstr .. ":null"
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--------------------------------------------------------------------------------
-- SECTION 3: UI HELPERS
--------------------------------------------------------------------------------

-- Display the welcome / intro dialog.
local function show_welcome(display)
    local result = MessageBox({
        title          = "SekonicCalibrator v0.2",
        message        = "Lighttune – GrandMA3 Color Calibration\n\n"
                       .. "Calibrate fixture groups using measurements\n"
                       .. "from your Sekonic C-7000 spectromaster.\n\n"
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
-- Returns { cri, r9, tlci } (each a goal table) or nil on cancel.
local function get_spectral_goals(display)
    local choice = MessageBox({
        title          = "Quality Goals",
        message        = "Which colour quality metrics to track?\n\n"
                       .. "  CRI & R9      – general rendering + deep red\n"
                       .. "  All three     – CRI, R9, and TLCI (broadcast camera)\n"
                       .. "  Custom        – choose each metric individually\n"
                       .. "  Skip          – no quality tracking",
        display_handle = display,
        buttons        = { "CRI & R9", "All three", "Custom", "Skip" },
    })
    if choice == nil then return nil end

    local track_cri, track_r9, track_tlci

    if choice == 1 then
        track_cri = true; track_r9 = true; track_tlci = false
    elseif choice == 2 then
        track_cri = true; track_r9 = true; track_tlci = true
    elseif choice == 4 then
        return { cri = { mode=GOAL_SKIP }, r9 = { mode=GOAL_SKIP }, tlci = { mode=GOAL_SKIP } }
    else  -- Custom
        local sel = MessageBox({
            title          = "Custom Metrics",
            message        = "Select metrics to track (choose one combination):\n\n"
                           .. "  CRI only     R9 only     TLCI only",
            display_handle = display,
            buttons        = { "CRI only", "R9 only", "TLCI only" },
        })
        if sel == nil then return nil end
        track_cri  = (sel == 1)
        track_r9   = (sel == 2)
        track_tlci = (sel == 3)
    end

    local cri_goal, r9_goal, tlci_goal

    if track_cri then
        cri_goal = get_one_spectral_goal(display, "CRI (Ra)", 90)
        if not cri_goal then return nil end
    else
        cri_goal = { mode = GOAL_SKIP }
    end

    if track_r9 then
        r9_goal = get_one_spectral_goal(display, "R9", 80)
        if not r9_goal then return nil end
    else
        r9_goal = { mode = GOAL_SKIP }
    end

    if track_tlci then
        tlci_goal = get_one_spectral_goal(display, "TLCI", 75)
        if not tlci_goal then return nil end
    else
        tlci_goal = { mode = GOAL_SKIP }
    end

    return { cri = cri_goal, r9 = r9_goal, tlci = tlci_goal }
end

-- Collect reference group CCT and Duv (reference mode only).
-- Returns { cct, duv } or nil on cancel.
local function get_reference_measurements(display, ref_group)
    local cct = get_number_input(
        display,
        "Reference CCT – " .. ref_group,
        string.format(
            "Measure '%s' with your Sekonic C-7000.\n\n"
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
-- Returns goals table or nil on cancel.
local function get_session_goals(display)
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

    local cal_mode = (mode_choice == 1) and MODE_TARGET or MODE_REFERENCE
    local ref_group = nil
    local cct, duv

    if cal_mode == MODE_REFERENCE then
        -- Ask for reference group name
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

        -- Measure the reference group
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
    local spectral = get_spectral_goals(display)
    if not spectral then return nil end

    return {
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

-- Prompt for fixture make/model (optional, for the community log).
-- Returns string or "Unknown" if skipped.
local function get_fixture_model_input(display)
    local r = MessageBox({
        title          = "Fixture Model (optional)",
        message        = "Enter the fixture type/model for this group.\n"
                       .. "This is logged to the fixture database.\n\n"
                       .. "e.g.  Aputure 600X Pro\n"
                       .. "      Arri SkyPanel S60-C\n"
                       .. "      Chroma-Q Space Force\n\n"
                       .. "Leave blank to skip.",
        display_handle = display,
        input          = true,
        buttons        = { "OK", "Skip" },
    })
    if r == nil or r == 2 then return "Unknown" end
    local v = tostring(r):match("^%s*(.-)%s*$")
    return (v ~= "") and v or "Unknown"
end

-- Collect Sekonic C-7000 measurements for the current attempt.
-- goals is needed to know whether to ask for TLCI.
local function get_measurement_params(display, attempt, goals)
    local suffix = attempt > 1 and string.format(" (attempt %d)", attempt) or ""
    local track_tlci = goals.tlci and goals.tlci.mode ~= GOAL_SKIP

    local cct = get_number_input(
        display, "Measured CCT" .. suffix,
        string.format("CCT reading from Sekonic C-7000.\nRange: %d – %d K", CCT_MIN, CCT_MAX),
        CCT_MIN, CCT_MAX
    )
    if not cct then return nil end

    local duv = get_number_input(
        display, "Measured Duv" .. suffix,
        string.format(
            "Duv (\xce\x94uv) reading from Sekonic C-7000.\nRange: %g to %+g\n\n"
            .. "Shown as 'Deviation' or '\xce\x94uv' on the meter.\n"
            .. "+value = green  |  -value = magenta",
            DUV_MIN, DUV_MAX
        ),
        DUV_MIN, DUV_MAX
    )
    if not duv then return nil end

    local cri = get_number_input(
        display, "Measured CRI (Ra)" .. suffix,
        string.format("CRI (Ra) reading from Sekonic C-7000.\nRange: %d – %d", CRI_MIN, CRI_MAX),
        CRI_MIN, CRI_MAX
    )
    if not cri then return nil end

    local r9 = get_number_input(
        display, "Measured R9" .. suffix,
        string.format(
            "R9 (deep red) reading from Sekonic C-7000.\nRange: %d – %d\n\n"
            .. "Critical for skin tones and costumes on camera.",
            CRI_MIN, CRI_MAX
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

-- Show assessment + correction summary. Returns true = apply, false = skip.
local function show_assessment(display, group, goals, measured, correction, attempt)
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

    -- Gel + spectral hints
    local hints = {}
    local gh = gel_hint(measured.duv)
    if gh then hints[#hints + 1] = "  Gel:  " .. gh end
    if measured.cri < 85 then
        hints[#hints + 1] = "  CRI:  Cannot be improved via console – try a different"
        hints[#hints + 1] = "         fixture or enable the fixture's high-CRI mode"
    end
    if measured.r9 < 65 then
        hints[#hints + 1] = "  R9:   Low R9 is a fixture spectral issue – consider a"
        hints[#hints + 1] = "         high-R9 fixture or add a warming gel"
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

    -- TLCI row (only if measured)
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
                .. "Re-measure with Sekonic C-7000 to confirm.",
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

        -- Build status string
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

        -- Metrics line
        local metrics = ""
        if m then
            metrics = string.format("CRI:%d  R9:%d", m.cri, m.r9)
            if m.tlci then metrics = metrics .. string.format("  TLCI:%d", m.tlci) end
            metrics = metrics .. string.format("  Duv:%+.3f", m.duv)
        end

        local fixture_str = (entry.fixture and entry.fixture ~= "Unknown")
            and (" [" .. entry.fixture .. "]") or ""

        lines[#lines + 1] = string.format(
            "\nGroup: %s%s\n  %s  \xce\x94K:%s  (%d attempt%s)\n  Status: %s",
            entry.group, fixture_str,
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
-- SECTION 5: DATA LOGGING (local file + optional GitHub upload)
--------------------------------------------------------------------------------

-- Platform-appropriate null device and path separator.
local IS_WINDOWS  = package.config:sub(1, 1) == "\\"
local NULL_DEV    = IS_WINDOWS and "NUL" or "/dev/null"
local TMP_DIR     = IS_WINDOWS
    and (os.getenv("TEMP") or "C:\\Temp")
    or  "/tmp"

-- Resolve the plugin's data directory.
local function get_data_dir()
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

-- Create a directory if it doesn't exist (silent).
local function mkdir_p(path)
    if IS_WINDOWS then
        os.execute('mkdir "' .. path .. '" 2>' .. NULL_DEV)
    else
        os.execute('mkdir -p "' .. path .. '" 2>' .. NULL_DEV)
    end
end

-- Read config.json for optional GitHub token.
-- Returns { github_token = "..." } or nil.
local function load_config()
    local path = get_data_dir() .. (IS_WINDOWS and "\\" or "/") .. "config.json"
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local token = content:match('"github_token"%s*:%s*"([^"]+)"')
    if not token or token == "" then return nil end
    return { github_token = token }
end

-- Append an entry to the local fixture_log.json file.
local function save_fixture_log_local(entry)
    local ok, err = pcall(function()
        local sep   = IS_WINDOWS and "\\" or "/"
        local dir   = get_data_dir() .. sep .. "data"
        mkdir_p(dir)
        local path  = dir .. sep .. "fixture_log.json"

        -- Read existing array (or start fresh)
        local arr_str = "[]"
        local rf = io.open(path, "r")
        if rf then
            arr_str = rf:read("*a")
            rf:close()
        end

        -- Append: remove trailing ']', add new entry, close
        arr_str = arr_str:match("^%s*(.-)%s*$")
        if arr_str == "[]" or arr_str == "" then
            arr_str = "[" .. json_encode_entry(entry) .. "]"
        else
            -- Remove final ']' and append
            arr_str = arr_str:sub(1, -2) .. "," .. json_encode_entry(entry) .. "]"
        end

        local wf = io.open(path, "w")
        if wf then
            wf:write(arr_str)
            wf:close()
        end
    end)
    return ok, err
end

-- Execute curl and return stdout, or nil on error.
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

-- Upload a single fixture entry as a JSON file to the GitHub repository.
-- Each call creates a new file named by timestamp + fixture.
-- Silent on any failure.
local function upload_fixture_log(entry, config)
    if not config or not config.github_token then return false end

    -- Quick connectivity check (3s timeout)
    local check_cmd = string.format(
        'curl -s --max-time 3 -o %s -w "%%{http_code}" https://api.github.com 2>%s',
        NULL_DEV, NULL_DEV
    )
    local code = curl_exec(check_cmd)
    if not code or code:match("%d+") ~= "200" then return false end

    -- Build filename: data/measurements/YYYYMMDD_HHMMSS_Fixture.json
    local safe_name = (entry.fixture or "Unknown"):gsub("[^%w%-_]", "_")
    local ts        = os.date("%Y%m%d_%H%M%S")
    local filepath  = "data/measurements/" .. ts .. "_" .. safe_name .. ".json"
    local url       = string.format(
        "https://api.github.com/repos/%s/contents/%s",
        GITHUB_REPO, filepath
    )

    -- Encode content
    local json_body   = json_encode_entry(entry)
    local b64_content = base64_encode(json_body)

    -- Write PUT body to temp file (avoids shell quoting nightmares)
    local tmp_path = TMP_DIR .. (IS_WINDOWS and "\\" or "/") .. "sc_upload.json"
    local tf = io.open(tmp_path, "w")
    if not tf then return false end
    tf:write(string.format(
        '{"message":"Add fixture measurement: %s","content":"%s"}',
        (entry.fixture or "Unknown"):gsub('"', '\\"'),
        b64_content
    ))
    tf:close()

    local put_cmd = string.format(
        'curl -s -X PUT -H "Authorization: token %s" -H "Content-Type: application/json" '
        .. '-d @"%s" -o %s -w "%%{http_code}" "%s" 2>%s',
        config.github_token, tmp_path, NULL_DEV, url, NULL_DEV
    )
    local resp = curl_exec(put_cmd)
    return resp and (resp == "201" or resp == "200")
end

-- Orchestrate local save and optional upload. Never interrupts calibration.
-- Shows a one-time hint if the config file is missing but does not block.
local function log_fixture_data(display, entry, config)
    -- Local save (always attempted)
    local local_ok = pcall(save_fixture_log_local, entry)

    -- Upload (only when config has a token)
    if config and config.github_token then
        pcall(upload_fixture_log, entry, config)
    elseif local_ok then
        -- First time: gently inform about community upload (non-blocking)
        -- We use a lightweight check to avoid showing this every single time
        local flag_path = get_data_dir() .. (IS_WINDOWS and "\\" or "/") .. "data" .. (IS_WINDOWS and "\\" or "/") .. ".upload_hint_shown"
        local flag = io.open(flag_path, "r")
        if not flag then
            -- Flag not yet written → show hint once
            local wf = io.open(flag_path, "w")
            if wf then wf:write("1"); wf:close() end
            MessageBox({
                title   = "Community Upload",
                message = "Fixture measurements are saved locally.\n\n"
                        .. "To share with the community database, add\n"
                        .. "your GitHub token to:\n\n"
                        .. "  SekonicCalibrator/data/config.json\n\n"
                        .. '  { "github_token": "ghp_..." }\n\n'
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

        local config      = load_config()   -- GitHub token (may be nil)
        local session_log = {}

        -- ── Outer loop: group by group ──────────────────────────────────────
        repeat
            local group = get_group_input(display)
            if not group then break end

            local fixture_model = get_fixture_model_input(display)

            local attempt      = 0
            local last_measured    = nil
            local last_correction  = nil
            local applied_once     = false

            -- ── Inner loop: re-measure same group until happy ───────────────
            repeat
                attempt = attempt + 1

                local measured = get_measurement_params(display, attempt, goals)
                if not measured then
                    -- Operator cancelled mid-measurement → treat as done
                    break
                end

                last_measured = measured

                local correction = get_correction(
                    goals.cct, goals.duv,
                    measured.cct, measured.duv
                )
                last_correction = correction

                local apply = show_assessment(
                    display, group, goals, measured, correction, attempt
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

            -- Log fixture data (local + optional upload)
            if last_measured then
                local entry = {
                    date         = os.date("%Y-%m-%d"),
                    fixture      = fixture_model,
                    group        = group,
                    cct_measured = last_measured.cct,
                    duv_measured = last_measured.duv,
                    cri          = last_measured.cri,
                    r9           = last_measured.r9,
                    tlci         = last_measured.tlci,
                    cct_target   = goals.cct,
                    duv_target   = goals.duv,
                    attempts     = attempt,
                }
                log_fixture_data(display, entry, config)

                table.insert(session_log, {
                    group      = group,
                    fixture    = fixture_model,
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
