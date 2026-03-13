-- SekonicCalibrator v0.1
-- Lighttune - GrandMA3 Lua Plugin
--
-- Calibrate fixture groups using Sekonic C-7000 spectromaster measurements.
-- Session goals: target Kelvin, CRI goal, R9 goal.
-- Inner loop: re-measure the same group until the operator is happy.
-- Outer loop: move to the next group.

--------------------------------------------------------------------------------
-- SECTION 1: CONSTANTS
--------------------------------------------------------------------------------

local QUALITY = {
    CRI = { excellent = 95, good = 90, acceptable = 80 },
    R9  = { excellent = 90, good = 80, acceptable = 50 },
    DUV = { excellent = 0.003, good = 0.006, acceptable = 0.010 },
}

local CCT_MIN = 1667
local CCT_MAX = 25000
local DUV_MIN = -0.02
local DUV_MAX =  0.02
local CRI_MIN =  0
local CRI_MAX =  100

-- Goal modes for CRI / R9
local GOAL_MAX  = "max"   -- push as high as possible (informational)
local GOAL_MIN  = "min"   -- must reach a specific minimum value
local GOAL_SKIP = "skip"  -- not being tracked this session

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
    local up = 4 * x / denom
    local vp = 9 * y / denom
    return up, vp
end

-- Convert CIE 1976 u'v' back to CIE 1931 xy.
local function uvp_to_xy(up, vp)
    local denom = 6 * up - 16 * vp + 12
    if denom == 0 then return 0, 0 end
    local x = 9 * up / denom
    local y = 4 * vp / denom
    return x, y
end

-- Apply Duv correction to a CIE 1931 xy point.
-- measured_duv: deviation of the light source from Planckian locus (+green / -magenta)
-- target_duv:   desired deviation (usually 0.000)
-- The correction shifts v' (CIE 1976) to counteract the measured deviation.
-- Duv is defined in CIE 1960 uv space; v' = 1.5 * v_1960, so scale by 1.5.
local function apply_duv_correction(x, y, measured_duv, target_duv)
    local up, vp = xy_to_uvp(x, y)
    local delta = (target_duv - measured_duv) * 1.5
    vp = vp + delta
    return uvp_to_xy(up, vp)
end

-- Compute the target chromaticity for fixture output, plus correction deltas.
-- Returns: { target_x, target_y, delta_cct, delta_duv }
local function get_correction(tgt_cct, tgt_duv, meas_cct, meas_duv)
    -- Start from the target CCT Planckian point, then apply target Duv offset.
    local tx, ty = cct_to_xy(tgt_cct)
    tx, ty = apply_duv_correction(tx, ty, 0, tgt_duv)
    return {
        target_x  = tx,
        target_y  = ty,
        delta_cct = tgt_cct - meas_cct,
        delta_duv = tgt_duv - meas_duv,
    }
end

-- Convert CIE 1931 xy chromaticity to normalised sRGB (0–1 each channel).
-- Assumes Y = 1.0. Normalises so the brightest channel = 1 (preserves hue/sat).
local function xy_to_rgb(x, y)
    if y == 0 then y = 0.0001 end
    local X = x / y
    local Y = 1.0
    local Z = (1 - x - y) / y

    -- XYZ to linear sRGB (IEC 61966-2-1 D65 matrix)
    local r_lin =  3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
    local g_lin = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
    local b_lin =  0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z

    r_lin = math.max(0, r_lin)
    g_lin = math.max(0, g_lin)
    b_lin = math.max(0, b_lin)

    -- Normalise so max channel = 1 (preserves hue and saturation)
    local max_c = math.max(r_lin, g_lin, b_lin)
    if max_c > 0 then
        r_lin = r_lin / max_c
        g_lin = g_lin / max_c
        b_lin = b_lin / max_c
    end

    -- Gamma encode (sRGB approx: 2.2)
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
    if value >= thresholds.excellent then return "Excellent"
    elseif value >= thresholds.good   then return "Good"
    elseif value >= thresholds.acceptable then return "Acceptable"
    else return "Poor"
    end
end

-- Rate Duv (inverted scale: lower absolute value = better).
local function rate_duv(duv)
    local abs_duv = math.abs(duv)
    if abs_duv <= QUALITY.DUV.excellent  then return "Excellent"
    elseif abs_duv <= QUALITY.DUV.good   then return "Good"
    elseif abs_duv <= QUALITY.DUV.acceptable then return "Acceptable"
    else return "Poor"
    end
end

-- Return a concise goal-status string for CRI or R9.
-- goal: { mode = GOAL_MAX / GOAL_MIN / GOAL_SKIP, value = N (for GOAL_MIN) }
local function goal_status_str(measured_val, goal)
    if goal.mode == GOAL_SKIP then
        return ""
    elseif goal.mode == GOAL_MAX then
        return "  [maximize]"
    else  -- GOAL_MIN
        if measured_val >= goal.value then
            return string.format("  [GOAL MET \xe2\x89\xa5%d]", goal.value)
        else
            return string.format("  [BELOW GOAL – need %d, have %d]", goal.value, measured_val)
        end
    end
end

--------------------------------------------------------------------------------
-- SECTION 3: UI HELPERS
--------------------------------------------------------------------------------

-- Display the welcome / intro dialog.
-- Returns true to proceed, false if the user cancels.
local function show_welcome(display)
    local result = MessageBox({
        title          = "SekonicCalibrator v0.1",
        message        = "Lighttune – GrandMA3 Color Calibration\n\n"
                       .. "Calibrate fixture groups using measurements\n"
                       .. "from your Sekonic C-7000 spectromaster.\n\n"
                       .. "Session goals are set once:\n"
                       .. "  • Target Kelvin\n"
                       .. "  • CRI and/or R9 goals\n\n"
                       .. "Each group is re-measured until you are happy,\n"
                       .. "then you move on to the next group.",
        display_handle = display,
        buttons        = { "Start", "Cancel" },
    })
    return result == 1
end

-- Prompt for a single numeric parameter with range validation.
-- Re-prompts up to 3 times on invalid input.
-- Returns the number or nil on cancel.
local function get_number_input(display, title, message, min_val, max_val)
    for attempt = 1, 3 do
        local prefix = ""
        if attempt > 1 then
            prefix = string.format("Value must be between %g and %g.\n\n", min_val, max_val)
        end
        local result = MessageBox({
            title          = title,
            message        = prefix .. message,
            display_handle = display,
            input          = true,
            buttons        = { "OK", "Cancel" },
        })
        if result == nil or result == 2 then return nil end
        local num = tonumber(tostring(result))
        if num ~= nil and num >= min_val and num <= max_val then
            return num
        end
    end
    return nil
end

-- Prompt for the mode and optional minimum for a single spectral metric.
-- metric_name: "CRI (Ra)" or "R9", typical_min: broadcast reference value.
-- Returns a goal table { mode, value } or nil on cancel.
local function get_one_spectral_goal(display, metric_name, typical_min)
    local mode_result = MessageBox({
        title          = metric_name .. " Goal",
        message        = string.format(
            "Set the goal for %s.\n\n"
            .. "  As high as possible – track quality, no hard floor\n"
            .. "  Set minimum         – flag groups that fall below a value\n"
            .. "  Skip                – not tracking %s this session",
            metric_name, metric_name
        ),
        display_handle = display,
        buttons        = { "As high as possible", "Set minimum", "Skip" },
    })

    if mode_result == nil then return nil end
    if mode_result == 1   then return { mode = GOAL_MAX } end
    if mode_result == 3   then return { mode = GOAL_SKIP } end

    -- mode_result == 2: ask for the minimum value
    local val = get_number_input(
        display,
        metric_name .. " Minimum",
        string.format(
            "Enter the minimum acceptable %s value.\n"
            .. "Range: %d – %d\n\n"
            .. "Broadcast standard: %d+",
            metric_name, CRI_MIN, CRI_MAX, typical_min
        ),
        CRI_MIN, CRI_MAX
    )
    if not val then return nil end
    return { mode = GOAL_MIN, value = val }
end

-- Collect all session goals once at the start.
-- Target Duv is fixed at 0.000 (Planckian locus neutral) – not user-configurable.
-- Returns { cct, duv, cri, r9 } or nil on cancel.
-- cri / r9 are goal tables: { mode = GOAL_MAX/MIN/SKIP, value = N }
local function get_session_goals(display)
    -- Target Kelvin
    local cct = get_number_input(
        display,
        "Target Color Temperature",
        string.format(
            "Enter the target CCT in Kelvin for this session.\n"
            .. "Range: %d – %d\n\n"
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

    -- Duv is always targeted at 0.000 (neutral, on Planckian locus).
    -- The measured Duv is still entered per-reading so the correction math works.
    local duv = 0.000

    -- ── Spectral goal selection ───────────────────────────────────────────
    -- Ask which metrics to track, with a "both" shortcut.
    local spectral_choice = MessageBox({
        title          = "Spectral Goals",
        message        = "Which colour quality metrics do you want to track?\n\n"
                       .. "  CRI (Ra)      – General colour rendering index\n"
                       .. "  R9            – Deep red rendering (skin tones)\n"
                       .. "  Both          – Track CRI and R9\n"
                       .. "  Skip          – Quality metrics not tracked",
        display_handle = display,
        buttons        = { "CRI only", "R9 only", "Both", "Skip" },
    })
    if spectral_choice == nil then return nil end

    local track_cri = (spectral_choice == 1 or spectral_choice == 3)
    local track_r9  = (spectral_choice == 2 or spectral_choice == 3)

    local cri_goal, r9_goal

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

    return { cct = cct, duv = duv, cri = cri_goal, r9 = r9_goal }
end

-- Prompt for the group number/name to calibrate.
-- Returns the group string or nil on cancel.
local function get_group_input(display)
    for attempt = 1, 3 do
        local prefix = attempt > 1 and "Invalid input. Please enter a number or name.\n\n" or ""
        local result = MessageBox({
            title          = "Select Fixture Group",
            message        = prefix .. "Enter the group number or name to calibrate:\n(e.g.  1  or  Front Wash)",
            display_handle = display,
            input          = true,
            buttons        = { "OK", "Cancel" },
        })
        if result == nil or result == 2 then return nil end
        local val = tostring(result):match("^%s*(.-)%s*$")
        if val ~= "" then return val end
    end
    return nil
end

-- Collect measured CCT, Duv, CRI (Ra), and R9 from the Sekonic C-7000 readout.
-- Returns { cct, duv, cri, r9 } or nil on cancel.
local function get_measurement_params(display, attempt)
    local title_suffix = attempt > 1 and string.format(" (attempt %d)", attempt) or ""

    local cct = get_number_input(
        display,
        "Measured CCT" .. title_suffix,
        string.format(
            "Enter the CCT reading from your Sekonic C-7000.\n"
            .. "Range: %d – %d K",
            CCT_MIN, CCT_MAX
        ),
        CCT_MIN, CCT_MAX
    )
    if not cct then return nil end

    local duv = get_number_input(
        display,
        "Measured Duv" .. title_suffix,
        string.format(
            "Enter the Duv (\xce\x94uv) reading from your Sekonic C-7000.\n"
            .. "Range: %g to %+g\n\n"
            .. "Shown as 'Deviation' or '\xce\x94uv' on the meter.\n"
            .. "+value = green  |  -value = magenta",
            DUV_MIN, DUV_MAX
        ),
        DUV_MIN, DUV_MAX
    )
    if not duv then return nil end

    local cri = get_number_input(
        display,
        "Measured CRI (Ra)" .. title_suffix,
        string.format(
            "Enter the CRI (Ra) reading from your Sekonic C-7000.\n"
            .. "Range: %d – %d",
            CRI_MIN, CRI_MAX
        ),
        CRI_MIN, CRI_MAX
    )
    if not cri then return nil end

    local r9 = get_number_input(
        display,
        "Measured R9" .. title_suffix,
        string.format(
            "Enter the R9 (deep red) reading from your Sekonic C-7000.\n"
            .. "Range: %d – %d\n\n"
            .. "R9 measures saturated red reproduction –\n"
            .. "critical for skin tones and costumes on camera.",
            CRI_MIN, CRI_MAX
        ),
        CRI_MIN, CRI_MAX
    )
    if not r9 then return nil end

    return { cct = cct, duv = duv, cri = cri, r9 = r9 }
end

-- Build a goals summary line for the assessment header.
local function goals_summary_line(goals)
    local cri_str
    if goals.cri.mode == GOAL_MAX then
        cri_str = "maximize"
    elseif goals.cri.mode == GOAL_MIN then
        cri_str = string.format("\xe2\x89\xa5%d", goals.cri.value)
    else
        cri_str = "skipped"
    end

    local r9_str
    if goals.r9.mode == GOAL_MAX then
        r9_str = "maximize"
    elseif goals.r9.mode == GOAL_MIN then
        r9_str = string.format("\xe2\xa9\xbe%d", goals.r9.value)
    else
        r9_str = "skipped"
    end

    return string.format(
        "Goals: %dK  CRI:%s  R9:%s",
        goals.cct, cri_str, r9_str
    )
end

-- Show the quality assessment and correction summary.
-- Buttons: [Apply] [Skip]
-- Returns true = apply correction, false = skip (but continue loop).
local function show_assessment(display, group, goals, measured, correction, attempt)
    local cri_rating = rate_quality(measured.cri, QUALITY.CRI)
    local r9_rating  = rate_quality(measured.r9,  QUALITY.R9)
    local duv_rating = rate_duv(measured.duv)

    local cri_goal_str = goal_status_str(measured.cri, goals.cri)
    local r9_goal_str  = goal_status_str(measured.r9,  goals.r9)

    -- Broadcast warnings
    local warnings = ""
    if measured.cri < QUALITY.CRI.acceptable then
        warnings = warnings .. "  WARNING: CRI below broadcast minimum (80)\n"
    end
    if measured.r9 < QUALITY.R9.acceptable then
        warnings = warnings .. "  WARNING: R9 below broadcast minimum (50)\n"
        warnings = warnings .. "           Reds may appear dull on camera\n"
    end
    if math.abs(measured.duv) > QUALITY.DUV.acceptable then
        warnings = warnings .. "  WARNING: Strong green/magenta cast (|Duv| > 0.010)\n"
    end
    if warnings ~= "" then
        warnings = "\n" .. warnings
    end

    local delta_cct_str
    if correction.delta_cct > 0 then
        delta_cct_str = string.format("+%dK", correction.delta_cct)
    elseif correction.delta_cct < 0 then
        delta_cct_str = string.format("%dK", correction.delta_cct)
    else
        delta_cct_str = "0K (on target)"
    end

    local delta_duv_str
    if correction.delta_duv > 0 then
        delta_duv_str = string.format("+%.4f", correction.delta_duv)
    elseif correction.delta_duv < 0 then
        delta_duv_str = string.format("%.4f", correction.delta_duv)
    else
        delta_duv_str = "0.000 (on target)"
    end

    local msg = string.format(
        "Group: %s  |  Attempt %d\n"
     .. "%s\n\n"
     .. "== Quality ==\n\n"
     .. "  CRI (Ra) :  %3d  \xe2\x86\x92  %-11s%s\n"
     .. "  R9       :  %3d  \xe2\x86\x92  %-11s%s\n"
     .. "  Duv      : %+.4f  \xe2\x86\x92  %-11s\n"
     .. "%s\n"
     .. "== Correction ==\n\n"
     .. "  Measured :  %dK  Duv %+.4f\n"
     .. "  Target   :  %dK  Duv %+.4f\n"
     .. "  \xce\x94 Kelvin  :  %s\n"
     .. "  \xce\x94 Duv     :  %s\n\n"
     .. "Apply chromaticity correction to Group %s?",
        group, attempt,
        goals_summary_line(goals),
        measured.cri, cri_rating, cri_goal_str,
        measured.r9,  r9_rating,  r9_goal_str,
        measured.duv, duv_rating,
        warnings,
        measured.cct, measured.duv,
        goals.cct,    goals.duv,
        delta_cct_str,
        delta_duv_str,
        group
    )

    local result = MessageBox({
        title          = string.format("Assessment – Group %s (attempt %d)", group, attempt),
        message        = msg,
        display_handle = display,
        buttons        = { "Apply", "Skip" },
    })
    return result == 1
end

-- Show the result of a calibration apply.
local function show_result(display, success, group, method, err_msg)
    if success then
        MessageBox({
            title          = "Correction Applied",
            message        = string.format(
                "Chromaticity correction applied to Group %s.\n\n"
                .. "Method: %s\n\n"
                .. "Re-measure the group with your Sekonic C-7000\n"
                .. "to confirm the result.",
                group, method
            ),
            display_handle = display,
            buttons        = { "OK" },
        })
    else
        MessageBox({
            title          = "Apply Failed",
            message        = string.format(
                "Could not apply correction to Group %s.\n\n"
                .. "Error: %s\n\n"
                .. "Check that the group exists and fixtures are patched.",
                group, tostring(err_msg)
            ),
            display_handle = display,
            buttons        = { "OK" },
        })
    end
end

-- Ask whether the operator is done with the current group.
-- Returns true = move to next group, false = measure again.
local function ask_group_done(display, group, attempt)
    local result = MessageBox({
        title          = string.format("Group %s – Done?", group),
        message        = string.format(
            "Group: %s  |  Attempt %d\n\n"
            .. "Are you happy with this group?\n\n"
            .. "  Done          – mark group complete and move on\n"
            .. "  Measure Again – re-take a Sekonic reading for this group",
            group, attempt
        ),
        display_handle = display,
        buttons        = { "Done", "Measure Again" },
    })
    return result == 1
end

-- Ask whether to calibrate another group.
local function ask_calibrate_another(display)
    local result = MessageBox({
        title          = "Next Group?",
        message        = "Calibrate another fixture group?",
        display_handle = display,
        buttons        = { "Yes", "No – Finish" },
    })
    return result == 1
end

--------------------------------------------------------------------------------
-- SECTION 4: FIXTURE APPLICATION
--------------------------------------------------------------------------------

-- Select a fixture group on the console.
-- Returns success (bool), error_message (string or nil).
local function select_group(group)
    local cmd = 'Group "' .. tostring(group) .. '"'
    local ok, err = pcall(function() Cmd(cmd) end)
    if not ok then
        -- Try without quotes (numeric IDs may not need them on all versions)
        local ok2, err2 = pcall(function() Cmd("Group " .. tostring(group)) end)
        if not ok2 then
            return false, tostring(err2)
        end
    end
    return true, nil
end

-- Attempt to set fixture color using xyY color model.
-- Returns success (bool), error_message (string or nil).
local function apply_color_xyY(x, y)
    local ok, err = pcall(function()
        -- x, y: CIE 1931 chromaticity; Y=1.0 (brightness controlled separately)
        SetColor("xyY", x, y, 1.0, 1.0, 1.0, false)
    end)
    if not ok then return false, tostring(err) end
    return true, nil
end

-- Fallback: set fixture color using HSB (for fixtures without xyY support).
-- Returns success (bool), error_message (string or nil).
local function apply_color_hsb(x, y)
    local r, g, b = xy_to_rgb(x, y)
    local h, s, _ = rgb_to_hsb(r, g, b)
    local ok, err = pcall(function()
        SetColor("HSB", h, s, 1.0, 1.0, 1.0, false)
    end)
    if not ok then return false, tostring(err) end
    return true, nil
end

-- Select a group and apply the corrected chromaticity.
-- Tries xyY first; falls back to HSB if xyY is unsupported.
-- Returns { success, method, error_msg }.
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
-- SECTION 5: MAIN ENTRY POINT
--------------------------------------------------------------------------------

local function main(display, ...)
    local ok, err = pcall(function()

        -- ── Welcome ──────────────────────────────────────────────────────────
        if not show_welcome(display) then return end

        -- ── Session goals (set once for all groups) ───────────────────────
        local goals = get_session_goals(display)
        if not goals then return end

        -- ── Outer loop: group by group ────────────────────────────────────
        repeat
            local group = get_group_input(display)
            if not group then break end

            local attempt = 0

            -- ── Inner loop: re-measure same group until happy ─────────────
            repeat
                attempt = attempt + 1

                local measured = get_measurement_params(display, attempt)
                if not measured then
                    -- Operator cancelled mid-measurement → treat as done with group
                    break
                end

                local correction = get_correction(
                    goals.cct, goals.duv,
                    measured.cct, measured.duv
                )

                local apply = show_assessment(
                    display, group, goals, measured, correction, attempt
                )

                if apply then
                    local result = calibrate_group(
                        group,
                        correction.target_x,
                        correction.target_y
                    )
                    show_result(
                        display, result.success, group,
                        result.method, result.error_msg
                    )
                end

            until ask_group_done(display, group, attempt)
            -- ─────────────────────────────────────────────────────────────

        until not ask_calibrate_another(display)
        -- ─────────────────────────────────────────────────────────────────

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
