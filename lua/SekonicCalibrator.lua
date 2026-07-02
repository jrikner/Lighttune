-- SekonicCalibrator v0.5.0-replan
-- Lighttune - GrandMA3 Lua Plugin
--
-- Calibrate fixture groups using Sekonic spectromaster measurements.
-- Supported meters: C-700, C-800 (no TLCI), C-7000 (full).
-- Features: session goals, per-group inner loop, session summary, gel hints,
--   TLCI metric, reference group mode, advanced Duv, GDTF capability detection,
--   fixture name from MA3 patch, append-only fixture database with best-value
--   flags, in-console fixture history viewer, remote bridge measurement via
--   Sekonic C-7000 over network (Raspberry Pi bridge, auto-loop calibration,
--   USB device auto-discovery and self-configuration).


--------------------------------------------------------------------------------
-- DOMAIN MODULE LOADER (Phase 2 — require + dofile fallback per D-23)
--------------------------------------------------------------------------------

local function load_domain_modules()
    local plugin_dir
    if GetPath and Enums then
        local ok, dir = pcall(function()
            return GetPath(Enums.PathType.PluginLibrary)
        end)
        if ok and dir then plugin_dir = dir end
    end
    if not plugin_dir then
        plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)[/\][^/\]+$")
            or "."
    end
    package.path = plugin_dir .. "/lua/?.lua;" .. package.path

    local function try_require(name)
        local ok, mod = pcall(require, name)
        if ok and type(mod) == "table" then return mod end
        local chunk, err = loadfile(plugin_dir .. "/lua/" .. name .. ".lua")
        if not chunk then error("module " .. name .. ": " .. tostring(err)) end
        mod = chunk()
        if type(mod) ~= "table" then error("module " .. name .. " must return a table") end
        package.loaded[name] = mod
        return mod
    end

    return {
        color_math     = try_require("color_math"),
        fixture_db     = try_require("fixture_db"),
        goals          = try_require("goals"),
        bridge_client  = try_require("bridge_client"),
        patch_api      = try_require("patch_api"),
        fixture_apply  = try_require("fixture_apply"),
    }
end

local domain = load_domain_modules()
local color_math     = domain.color_math
local fixture_db     = domain.fixture_db
local goal_eval      = domain.goals
local bridge_client  = domain.bridge_client
local config_mod     = domain.config
local patch_api      = domain.patch_api
local fixture_apply  = domain.fixture_apply
local QUALITY     = goal_eval.QUALITY
local GOAL_MAX    = goal_eval.GOAL_MAX
local GOAL_MIN    = goal_eval.GOAL_MIN
local GOAL_SKIP   = goal_eval.GOAL_SKIP
local CCT_MIN     = color_math.CCT_MIN
local CCT_MAX     = color_math.CCT_MAX
local DUV_MIN     = color_math.DUV_MIN
local DUV_MAX     = color_math.DUV_MAX
local GEL_STEPS   = color_math.GEL_STEPS

--------------------------------------------------------------------------------
-- SECTION 1: CONSTANTS
--------------------------------------------------------------------------------

local CRI_MIN =  0
local CRI_MAX =  100

local MODE_TARGET    = "target"
local MODE_REFERENCE = "reference"

local METER_C700  = "c700"   -- C-700 / C-800: no TLCI
local METER_C7000 = "c7000"  -- C-7000: full, includes TLCI


-- Unicode star used in history display to mark best values (★)
local STAR = "\xe2\x98\x85"

--------------------------------------------------------------------------------
-- SECTION 2: COLOR MATH → lua/color_math.lua
-- SECTION 2b: FIXTURE DB → lua/fixture_db.lua
-- goals → lua/goals.lua

--------------------------------------------------------------------------------
-- SECTION 3: UI HELPERS
-- Forward declarations for bridge functions (defined in Section 2c, below).
local format_bridge_error
local bridge_fetch_measurement
local run_bridge_setup
local show_bridge_status
local _run_trigger_discovery
--------------------------------------------------------------------------------

local function get_number_input(display, title, message, min_val, max_val)
    for attempt = 1, 3 do
        local prefix = attempt > 1
            and string.format("Value must be between %g and %g.\n\n", min_val, max_val) or ""
        local result = MessageBox({
            title=title, message=prefix..message, display_handle=display,
            input=true, buttons={"OK","Cancel"},
        })
        if result == nil or result == 2 then return nil end
        local num = tonumber(tostring(result))
        if num and num >= min_val and num <= max_val then return num end
    end
    return nil
end

local function get_one_spectral_goal(display, metric_name, typical_min)
    local r = MessageBox({
        title   = metric_name.." Goal",
        message = string.format(
            "Set the goal for %s.\n\n"
            .."  As high as possible – track quality, no hard floor\n"
            .."  Set minimum         – flag groups below a threshold\n"
            .."  Skip                – not tracking %s this session",
            metric_name, metric_name),
        display_handle = display,
        buttons = {"As high as possible","Set minimum","Skip"},
    })
    if r == nil then return nil end
    if r == 1   then return { mode=GOAL_MAX } end
    if r == 3   then return { mode=GOAL_SKIP } end
    local val = get_number_input(
        display, metric_name.." Minimum",
        string.format("Enter the minimum acceptable %s value.\nRange: %d – %d\n\nBroadcast standard: %d+",
            metric_name, CRI_MIN, CRI_MAX, typical_min),
        CRI_MIN, CRI_MAX)
    if not val then return nil end
    return { mode=GOAL_MIN, value=val }
end

local function get_spectral_goals(display, meter)
    local allow_tlci = (meter == METER_C7000)
    local choice
    if allow_tlci then
        choice = MessageBox({
            title   = "Quality Goals",
            message = "Which colour quality metrics to track?\n\n"
                    .."  CRI & R9      – general rendering + deep red\n"
                    .."  All three     – CRI, R9, and TLCI (broadcast camera)\n"
                    .."  Custom        – choose each metric individually\n"
                    .."  Skip          – no quality tracking",
            display_handle = display,
            buttons = {"CRI & R9","All three","Custom","Skip"},
        })
    else
        choice = MessageBox({
            title   = "Quality Goals",
            message = "Which colour quality metrics to track?\n\n"
                    .."  CRI & R9      – general rendering + deep red\n"
                    .."  CRI only      – general colour rendering\n"
                    .."  R9 only       – deep red rendering\n"
                    .."  Skip          – no quality tracking\n\n"
                    .."Note: TLCI requires Sekonic C-7000",
            display_handle = display,
            buttons = {"CRI & R9","CRI only","R9 only","Skip"},
        })
    end
    if choice == nil then return nil end

    local track_cri, track_r9, track_tlci = false, false, false
    local skip_all = false

    if allow_tlci then
        if     choice==1 then track_cri=true; track_r9=true
        elseif choice==2 then track_cri=true; track_r9=true; track_tlci=true
        elseif choice==4 then skip_all=true
        else
            local sel = MessageBox({ title="Custom Metrics",
                message="Select one metric:\n\n  CRI only   R9 only   TLCI only",
                display_handle=display, buttons={"CRI only","R9 only","TLCI only"} })
            if sel==nil then return nil end
            track_cri=(sel==1); track_r9=(sel==2); track_tlci=(sel==3)
        end
    else
        if     choice==1 then track_cri=true; track_r9=true
        elseif choice==2 then track_cri=true
        elseif choice==3 then track_r9=true
        else skip_all=true end
    end

    if skip_all then
        return { cri={mode=GOAL_SKIP}, r9={mode=GOAL_SKIP}, tlci={mode=GOAL_SKIP} }
    end

    local cri_goal  = track_cri  and get_one_spectral_goal(display,"CRI (Ra)",90) or {mode=GOAL_SKIP}
    if track_cri  and not cri_goal  then return nil end
    local r9_goal   = track_r9   and get_one_spectral_goal(display,"R9",      80) or {mode=GOAL_SKIP}
    if track_r9   and not r9_goal   then return nil end
    local tlci_goal = track_tlci and get_one_spectral_goal(display,"TLCI",    75) or {mode=GOAL_SKIP}
    if track_tlci and not tlci_goal then return nil end

    return { cri=cri_goal, r9=r9_goal, tlci=tlci_goal }
end

local function get_reference_measurements(display, ref_group)
    local cct = get_number_input(display,"Reference CCT – "..ref_group,
        string.format("Measure '%s' with your Sekonic meter.\n\nEnter the measured CCT (Kelvin).\nRange: %d – %d",
            ref_group, CCT_MIN, CCT_MAX), CCT_MIN, CCT_MAX)
    if not cct then return nil end
    local duv = get_number_input(display,"Reference Duv – "..ref_group,
        string.format("Enter the measured Duv for '%s'.\nRange: %g to %+g\n\n+value = green  |  -value = magenta",
            ref_group, DUV_MIN, DUV_MAX), DUV_MIN, DUV_MAX)
    if not duv then return nil end
    return { cct=cct, duv=duv }
end

local function get_session_goals(display)
    -- Meter model
    local mc = MessageBox({
        title="Sekonic Meter Model",
        message="Which Sekonic meter are you using?\n\n"
              .."  C-700 / C-800  – CCT, Duv, CRI, R9  (no TLCI)\n"
              .."  C-7000         – CCT, Duv, CRI, R9, TLCI",
        display_handle=display, buttons={"C-700 / C-800","C-7000"} })
    if mc==nil then return nil end
    local meter = (mc==1) and METER_C700 or METER_C7000

    -- Calibration mode
    local mode_choice = MessageBox({
        title="Calibration Mode",
        message="Choose a calibration mode:\n\n"
              .."  Calibrate to target  – set a Kelvin target;\n"
              .."                         all groups corrected to it\n\n"
              .."  Match to reference   – measure one reference group\n"
              .."                         first; all others matched to it",
        display_handle=display, buttons={"Calibrate to target","Match to reference"} })
    if mode_choice==nil then return nil end

    local cal_mode  = (mode_choice==1) and MODE_TARGET or MODE_REFERENCE
    local ref_group = nil
    local cct, duv

    if cal_mode==MODE_REFERENCE then
        local rg = nil
        for attempt=1,3 do
            local prefix = attempt>1 and "Please enter a valid name.\n\n" or ""
            local r = MessageBox({ title="Reference Group",
                message=prefix.."Enter the name of the reference fixture group\n(e.g.  Front HMI  |  Key Light  |  1)",
                display_handle=display, input=true, buttons={"OK","Cancel"} })
            if r==nil or r==2 then return nil end
            local v = tostring(r):match("^%s*(.-)%s*$")
            if v~="" then rg=v; break end
        end
        if not rg then return nil end
        ref_group = rg
        local ref_meas = get_reference_measurements(display, ref_group)
        if not ref_meas then return nil end
        cct=ref_meas.cct; duv=ref_meas.duv
        MessageBox({ title="Reference Captured",
            message=string.format("Reference group: %s\n\n  CCT: %dK\n  Duv: %+.4f (%s)\n\nAll other groups will be matched to these values.",
                ref_group, cct, duv, color_math.rate_duv(duv)),
            display_handle=display, buttons={"OK"} })
    else
        cct = get_number_input(display,"Target Color Temperature",
            string.format("Enter the target CCT in Kelvin.\nRange: %d – %d\n\n"
                .."Common values:\n  3200K  Tungsten\n  4300K  Fluorescent\n"
                .."  5600K  Daylight\n  6500K  Overcast", CCT_MIN, CCT_MAX),
            CCT_MIN, CCT_MAX)
        if not cct then return nil end

        local duv_choice = MessageBox({ title="Target Duv",
            message="Target Duv (green-magenta deviation):\n\n"
                  .."  0.000 (neutral) – on the Planckian locus\n"
                  .."  Advanced        – set a custom Duv target",
            display_handle=display, buttons={"0.000 (neutral)","Advanced"} })
        if duv_choice==nil then return nil end
        if duv_choice==1 then
            duv=0.000
        else
            duv = get_number_input(display,"Custom Target Duv",
                string.format("Enter the target Duv deviation.\nRange: %g to %+g\n\n"
                    .." 0.000 = neutral\n+value = green  |  -value = magenta", DUV_MIN, DUV_MAX),
                DUV_MIN, DUV_MAX)
            if not duv then return nil end
        end
    end

    local spectral = get_spectral_goals(display, meter)
    if not spectral then return nil end

    return {
        meter=meter, mode=cal_mode, ref_group=ref_group,
        cct=cct, duv=duv,
        cri=spectral.cri, r9=spectral.r9, tlci=spectral.tlci,
    }
end

local function get_group_input(display)
    for attempt=1,3 do
        local prefix = attempt>1 and "Invalid input.\n\n" or ""
        local r = MessageBox({ title="Select Fixture Group",
            message=prefix.."Enter the group number or name to calibrate:\n(e.g.  1  or  Front Wash)",
            display_handle=display, input=true, buttons={"OK","Cancel"} })
        if r==nil or r==2 then return nil end
        local v = tostring(r):match("^%s*(.-)%s*$")
        if v~="" then return v end
    end
    return nil
end

-- Attempt to read fixture manufacturer and model from the MA3 patch (patch_api.lua).

-- Prompt for fixture make+model. Tries patch first, manual entry fallback.
local function get_fixture_model_input(display, group_name)
    local patch_make, patch_model = patch_api.get_fixture_from_patch(group_name)

    if patch_make and patch_model then
        local r = MessageBox({ title="Fixture Identified",
            message=string.format("Fixture detected from patch:\n\n  Make:  %s\n  Model: %s\n\nUse this for the fixture database?",
                patch_make, patch_model),
            display_handle=display, buttons={"Yes, use this","Enter manually","Skip"} })
        if r==nil or r==3 then return nil, nil end
        if r==1 then return patch_make, patch_model end
    end

    local make_r = MessageBox({ title="Fixture Make",
        message="Enter the fixture manufacturer name.\ne.g.  Aputure  |  Arri  |  Chroma-Q\n\nLeave blank to skip fixture logging.",
        display_handle=display, input=true, buttons={"OK","Skip"} })
    if make_r==nil or make_r==2 then return nil, nil end
    local make = tostring(make_r):match("^%s*(.-)%s*$")
    if make=="" then return nil, nil end

    local model_r = MessageBox({ title="Fixture Model",
        message=string.format("Enter the model name for %s.\ne.g.  600X Pro  |  SkyPanel S60-C  |  Space Force", make),
        display_handle=display, input=true, buttons={"OK","Skip"} })
    if model_r==nil or model_r==2 then return nil, nil end
    local model = tostring(model_r):match("^%s*(.-)%s*$")
    if model=="" then return nil, nil end

    return make, model
end

-- Show prior data and offer to pre-apply the best known correction.
-- Called before the first measurement of a group when hist ~= nil.
local function apply_historical_prefill(display, group, hist, session_goals)
    local lines = {}
    if hist.best_cri  then lines[#lines+1]=string.format("  CRI:  %d  (%s)",  hist.best_cri.cri,  hist.best_cri.date  or "?") end
    if hist.best_r9   then lines[#lines+1]=string.format("  R9:   %d  (%s)",  hist.best_r9.r9,    hist.best_r9.date   or "?") end
    if hist.best_tlci then lines[#lines+1]=string.format("  TLCI: %d  (%s)",  hist.best_tlci.tlci,hist.best_tlci.date or "?") end
    if hist.best_duv  then lines[#lines+1]=string.format("  Duv:  %+.4f  (%s)",hist.best_duv.duv, hist.best_duv.date  or "?") end

    local r = MessageBox({ title="Prior Data Found",
        message=string.format(
            "Prior measurements found for this fixture @ %dK:\n\n%s\n\n"
            .."Pre-apply the best known correction now?\n"
            .."(Fixture will be set close to target before you measure.)",
            session_goals.cct, table.concat(lines,"\n")),
        display_handle=display,
        buttons={"Yes – Pre-apply","No – Measure cold"} })
    if r~=1 then return end

    -- Use best-Duv entry's CCT/Duv to compute correction
    local ref = hist.best_duv or hist.entries[1]
    if not ref or not ref.cct or not ref.duv then return end

    local correction = color_math.get_correction(session_goals.cct, session_goals.duv, ref.cct, ref.duv)
    -- calibrate_group is defined in Section 4 – call via pcall after it's defined
    -- (forward reference: we call it from main after all functions are defined)
    return correction.target_x, correction.target_y, ref.date
end

-- Collect Sekonic measurements. When hist is provided (first attempt),
-- prior best values are shown as context in each prompt.
-- When config contains bridge_ip the operator can trigger a remote measurement.
-- Returns: measured table (or nil on cancel), used_bridge (bool).
local function get_measurement_params(display, attempt, session_goals, hist, config)
    local suffix     = attempt>1 and string.format(" (attempt %d)", attempt) or ""
    local track_tlci = session_goals.tlci and session_goals.tlci.mode~=GOAL_SKIP
    local meter_name = (session_goals.meter==METER_C700) and "C-700/C-800" or "C-7000"

    -- ── Remote bridge mode (C-7000 session meter only — D-91) ───────────────
    if config and config.bridge_ip and config.bridge_ip ~= ""
       and session_goals.meter == METER_C7000 then
        ::bridge_retry::
        local mode = MessageBox({
            title   = "Measurement" .. suffix,
            message = string.format(
                "Bridge: %s:%d\n\n"
                .."How would you like to take this measurement?\n\n"
                .."  Remote   \xe2\x80\x93 trigger %s via bridge\n"
                .."            (console pauses ~2\xe2\x80\x935 s)\n\n"
                .."  Manual   \xe2\x80\x93 type values from meter display",
                config.bridge_ip, config.bridge_port or 8765, meter_name),
            display_handle = display,
            buttons = {"Remote Measurement", "Enter Manually", "Cancel"},
        })
        if mode == nil or mode == 3 then return nil, false end

        if mode == 1 then
            local measured, err = bridge_fetch_measurement(config)
            if measured then
                local tlci_line = measured.tlci
                    and string.format("\n  TLCI : %d", measured.tlci) or ""
                local conf = MessageBox({
                    title   = "Measurement Received" .. suffix,
                    message = string.format(
                        "Values from %s meter:\n\n"
                        .."  CCT  : %dK\n"
                        .."  Duv  : %+.4f\n"
                        .."  CRI  : %d\n"
                        .."  R9   : %d"
                        .."%s\n\nUse these values?",
                        meter_name,
                        measured.cct, measured.duv,
                        measured.cri, measured.r9, tlci_line),
                    display_handle = display,
                    buttons = {"Accept", "Re-measure", "Enter Manually"},
                })
                if conf == nil    then return nil, false end
                if conf == 1      then return measured, true end
                if conf == 2      then goto bridge_retry end
                -- conf == 3: fall through to manual entry
            else
                local err_r = MessageBox({
                    title   = "Bridge Error",
                    message = string.format(
                        "Could not get a measurement from the bridge.\n\n"
                        .."Error: %s\n\n"
                        .."Check:\n"
                        .."  \xe2\x80\xa2 Bridge is running on %s\n"
                        .."  \xe2\x80\xa2 C-7000 is connected via USB\n"
                        .."  \xe2\x80\xa2 Bridge IP in config.json is correct",
                        tostring(err), config.bridge_ip),
                    display_handle = display,
                    buttons = {"Retry Remote", "Enter Manually", "Cancel"},
                })
                if err_r == nil or err_r == 3 then return nil, false end
                if err_r == 1                  then goto bridge_retry end
                -- err_r == 2: fall through to manual entry
            end
        end
        -- mode == 2 or bridge fallback → continue to manual entry
    elseif config and config.bridge_ip and config.bridge_ip ~= ""
       and session_goals.meter == METER_C700 and attempt == 1 then
        -- D-92: bridge configured but C-700/C-800 session — manual only
    end
    -- ── Manual entry ──────────────────────────────────────────────────────────

    local function prior(rec, field, fmt)
        if attempt==1 and rec and rec[field]~=nil then
            return string.format("\n  Prior best: "..fmt.." (%s)", rec[field], rec.date or "?")
        end
        return ""
    end

    local cct = get_number_input(display,"Measured CCT"..suffix,
        string.format("CCT reading from Sekonic %s.\nRange: %d – %d K%s",
            meter_name, CCT_MIN, CCT_MAX,
            prior(hist and hist.best_duv, "cct", "%dK")),
        CCT_MIN, CCT_MAX)
    if not cct then return nil end

    local duv = get_number_input(display,"Measured Duv"..suffix,
        string.format("Duv (\xce\x94uv) from Sekonic %s.\nRange: %g to %+g\n\n"
            .."+value = green  |  -value = magenta%s",
            meter_name, DUV_MIN, DUV_MAX,
            prior(hist and hist.best_duv, "duv", "%+.4f")),
        DUV_MIN, DUV_MAX)
    if not duv then return nil end

    -- Show GDTF-rated CRI as context if available (passed via session_goals.gdtf_cri)
    local gdtf_cri_hint = (attempt==1 and session_goals.gdtf_cri)
        and string.format("\n  Manufacturer rated: %d", session_goals.gdtf_cri) or ""

    local cri = get_number_input(display,"Measured CRI (Ra)"..suffix,
        string.format("CRI (Ra) from Sekonic %s.\nRange: %d – %d%s%s",
            meter_name, CRI_MIN, CRI_MAX,
            gdtf_cri_hint,
            prior(hist and hist.best_cri, "cri", "%d")),
        CRI_MIN, CRI_MAX)
    if not cri then return nil end

    local r9 = get_number_input(display,"Measured R9"..suffix,
        string.format("R9 (deep red) from Sekonic %s.\nRange: %d – %d\n\n"
            .."Critical for skin tones and costumes on camera.%s",
            meter_name, CRI_MIN, CRI_MAX,
            prior(hist and hist.best_r9, "r9", "%d")),
        CRI_MIN, CRI_MAX)
    if not r9 then return nil end

    local tlci = nil
    if track_tlci then
        tlci = get_number_input(display,"Measured TLCI"..suffix,
            string.format("TLCI from Sekonic C-7000.\nRange: %d – %d\n\n"
                .."Television Lighting Consistency Index.\nBroadcast ready: 90+%s",
                CRI_MIN, CRI_MAX,
                prior(hist and hist.best_tlci, "tlci", "%d")),
            CRI_MIN, CRI_MAX)
        if not tlci then return nil end
    end

    return { cct=cct, duv=duv, cri=cri, r9=r9, tlci=tlci }, false
end

local function goals_summary_line(session_goals)
    local parts = { string.format("%dK", session_goals.cct) }
    if session_goals.duv~=0 then parts[#parts+1]=string.format("Duv%+.3f", session_goals.duv) end
    local function ms(label, goal)
        if not goal or goal.mode==GOAL_SKIP then return nil end
        if goal.mode==GOAL_MAX then return label..":max" end
        return string.format("%s:\xe2\x89\xa5%d", label, goal.value)
    end
    local s = ms("CRI",session_goals.cri);  if s then parts[#parts+1]=s end
    local s2= ms("R9", session_goals.r9);   if s2 then parts[#parts+1]=s2 end
    local s3= ms("TLCI",session_goals.tlci);if s3 then parts[#parts+1]=s3 end
    local prefix = session_goals.mode==MODE_REFERENCE
        and string.format("Ref: %s  |  ", session_goals.ref_group) or ""
    return prefix.."Goals: "..table.concat(parts,"  ")
end

-- Show quality assessment and correction summary.
-- caps (optional): GDTF capability table.
-- Returns true = apply, false = skip.
local function show_assessment(display, group, session_goals, measured, correction, attempt, caps)
    local cri_rating  = color_math.rate_quality(measured.cri, QUALITY.CRI)
    local r9_rating   = color_math.rate_quality(measured.r9,  QUALITY.R9)
    local tlci_rating = measured.tlci and color_math.rate_quality(measured.tlci, QUALITY.TLCI) or "n/a"
    local duv_rating  = color_math.rate_duv(measured.duv)

    local cri_gs  = goal_eval.goal_status_str(measured.cri,  session_goals.cri)
    local r9_gs   = goal_eval.goal_status_str(measured.r9,   session_goals.r9)
    local tlci_gs = measured.tlci and goal_eval.goal_status_str(measured.tlci, session_goals.tlci) or ""

    -- Warnings
    local warns = {}
    if measured.cri < QUALITY.CRI.acceptable then
        warns[#warns+1]="  WARNING: CRI below broadcast minimum (80)" end
    if measured.r9 < QUALITY.R9.acceptable then
        warns[#warns+1]="  WARNING: R9 below broadcast minimum (50)"
        warns[#warns+1]="           Reds may appear dull on camera" end
    if measured.tlci and measured.tlci < QUALITY.TLCI.acceptable then
        warns[#warns+1]="  WARNING: TLCI below broadcast minimum (50)" end
    if math.abs(measured.duv) > QUALITY.DUV.acceptable then
        warns[#warns+1]="  WARNING: Strong green/magenta cast (|Duv| > 0.010)" end
    local warns_str = #warns>0 and ("\n"..table.concat(warns,"\n").."\n") or ""

    -- Hints -------------------------------------------------------------------
    local hints = {}
    local duv_off = math.abs(measured.duv) > QUALITY.DUV.good  -- |Duv| > 0.006

    -- Duv / green-magenta correction ─────────────────────────────────────────
    if duv_off then
        local extreme = math.abs(measured.duv) > 0.020
        if caps then
            if caps.has_tint and not extreme then
                -- Fixture has Tint channel: steer it rather than applying physical gel
                local dir = measured.duv>0 and "negative (toward magenta)" or "positive (toward green)"
                hints[#hints+1]=string.format(
                    "  Tint channel: Shift toward %s to correct Duv %+.4f",
                    dir, measured.duv)
            elseif caps.has_color_wheel_filters then
                -- Fixture has gel/filter slots on its color wheel
                local slot_dir = measured.duv>0 and "Minus Green" or "Plus Green"
                hints[#hints+1]="  Color wheel: Use the "..slot_dir.." filter slot if available"
                local gh = color_math.gel_hint(measured.duv)
                if gh then hints[#hints+1]="  Physical gel (if no matching slot): "..gh end
            else
                -- No Tint, no filter wheel – physical gel is the only option
                local gh = color_math.gel_hint(measured.duv)
                if gh then hints[#hints+1]="  Gel (no Tint channel/filter wheel available): "..gh end
            end
            -- Extreme deviation: even Tint may not be enough
            if extreme and caps.has_tint then
                hints[#hints+1]="  Physical gel also required – Duv extreme, beyond Tint range"
                local gh = color_math.gel_hint(measured.duv)
                if gh then hints[#hints+1]="  "..gh end
            end
        else
            -- No GDTF data: show gel hint as safe fallback
            local gh = color_math.gel_hint(measured.duv)
            if gh then hints[#hints+1]="  Physical gel: "..gh end
        end
    end

    -- CCT correction console helpers ─────────────────────────────────────────
    if caps then
        local dk = correction.delta_cct
        if math.abs(dk)>200 then
            if dk<0 and caps.has_ctb then
                hints[#hints+1]="  CTB: Fixture has CTB channel – use to lower CCT" end
            if dk>0 and caps.has_cto then
                hints[#hints+1]="  CTO: Fixture has CTO channel – use to raise CCT" end
            if caps.has_color_wheel and not caps.has_color_wheel_filters then
                hints[#hints+1]="  Color wheel: Check for CTB/CTO correction slots" end
        end
    end

    -- Spectral limits (cannot be fixed via console) ──────────────────────────
    if measured.cri < 85 then
        hints[#hints+1]="  CRI: Cannot be improved via console – try a different"
        hints[#hints+1]="       fixture or enable the fixture's high-CRI mode" end
    if measured.r9 < 65 then
        hints[#hints+1]="  R9:  Low R9 is a spectral issue – consider a high-R9"
        hints[#hints+1]="       fixture or add a warming gel" end

    local hints_str = #hints>0
        and ("\n== Hints ==\n\n"..table.concat(hints,"\n").."\n") or ""

    -- Correction deltas
    local dkcct = correction.delta_cct; local dkduv = correction.delta_duv
    local dkcct_s = dkcct>0 and string.format("+%dK",dkcct)
                 or dkcct<0 and string.format("%dK", dkcct) or "0K (on target)"
    local dkduv_s = dkduv>0 and string.format("+%.4f",dkduv)
                 or dkduv<0 and string.format("%.4f", dkduv) or "0.000 (on target)"

    local tlci_row = measured.tlci
        and string.format("  TLCI     :  %3d  \xe2\x86\x92  %-11s%s\n",
            measured.tlci, tlci_rating, tlci_gs) or ""

    local msg = string.format(
        "Group: %s  |  Attempt %d\n%s\n\n"
     .."== Quality ==\n\n"
     .."  CRI (Ra) :  %3d  \xe2\x86\x92  %-11s%s\n"
     .."  R9       :  %3d  \xe2\x86\x92  %-11s%s\n"
     .."%s"
     .."  Duv      : %+.4f  \xe2\x86\x92  %-11s\n"
     .."%s\n"
     .."== Correction ==\n\n"
     .."  Measured :  %dK  Duv %+.4f\n"
     .."  Target   :  %dK  Duv %+.4f\n"
     .."  \xce\x94 Kelvin  :  %s\n"
     .."  \xce\x94 Duv     :  %s\n"
     .."%s\nApply correction to Group %s?",
        group, attempt, goals_summary_line(session_goals),
        measured.cri, cri_rating, cri_gs,
        measured.r9,  r9_rating,  r9_gs,
        tlci_row,
        measured.duv, duv_rating,
        warns_str,
        measured.cct, measured.duv,
        session_goals.cct, session_goals.duv,
        dkcct_s, dkduv_s,
        hints_str, group)

    local result = MessageBox({ title=string.format("Assessment – %s (attempt %d)",group,attempt),
        message=msg, display_handle=display, buttons={"Apply","Skip"} })
    return result==1
end

local function show_result(display, success, group, method, err_msg)
    if success then
        MessageBox({ title="Correction Applied",
            message=string.format("Correction applied to Group %s.\nMethod: %s\n\n"
                .."Re-measure with Sekonic meter to confirm.", group, method),
            display_handle=display, buttons={"OK"} })
    else
        MessageBox({ title="Apply Failed",
            message=string.format("Could not apply correction to Group %s.\n\nError: %s",
                group, tostring(err_msg)),
            display_handle=display, buttons={"OK"} })
    end
end

local function ask_group_done(display, group, attempt)
    local r = MessageBox({ title=string.format("Group %s – Done?", group),
        message=string.format("Group: %s  |  Attempt %d\n\nHappy with this group?\n\n"
            .."  Done          – mark complete and move on\n"
            .."  Measure Again – re-take a Sekonic reading", group, attempt),
        display_handle=display, buttons={"Done","Measure Again"} })
    return r==1
end

local function ask_calibrate_another(display)
    local r = MessageBox({ title="Next Group?", message="Calibrate another fixture group?",
        display_handle=display, buttons={"Yes","No – Finish"} })
    return r==1
end

local function show_session_summary(display, session_log, session_goals)
    if #session_log==0 then return end
    local lines = {
        string.format("== Session Summary  (%d group%s) ==\n", #session_log, #session_log==1 and "" or "s"),
        goals_summary_line(session_goals).."\n",
    }
    for _, entry in ipairs(session_log) do
        local m   = entry.measured
        local cor = entry.correction
        local dk  = cor and cor.delta_cct or 0
        local dk_str = dk>0 and string.format("+%dK",dk) or dk<0 and string.format("%dK",dk) or "0K"

        local fails = {}
        local function chk(label,val,goal)
            if not goal or goal.mode==GOAL_SKIP then return end
            if goal.mode==GOAL_MIN and val<goal.value then fails[#fails+1]=label end
        end
        if m then
            chk("CRI",m.cri,session_goals.cri); chk("R9",m.r9,session_goals.r9)
            if m.tlci then chk("TLCI",m.tlci,session_goals.tlci) end
        end
        local status = #fails==0 and "OK" or ("Below goal: "..table.concat(fails,", "))
        if session_goals.cri.mode==GOAL_SKIP and session_goals.r9.mode==GOAL_SKIP and session_goals.tlci.mode==GOAL_SKIP then
            status="goals skipped" end

        local metrics=""
        if m then
            metrics=string.format("CRI:%d  R9:%d",m.cri,m.r9)
            if m.tlci then metrics=metrics..string.format("  TLCI:%d",m.tlci) end
            metrics=metrics..string.format("  Duv:%+.3f",m.duv)
        end
        local fix_str=""
        if entry.make and entry.model then fix_str=string.format(" [%s %s]",entry.make,entry.model) end

        lines[#lines+1]=string.format(
            "\nGroup: %s%s\n  %s  \xce\x94K:%s  (%d attempt%s)\n  Status: %s",
            entry.group, fix_str, metrics, dk_str, entry.attempt,
            entry.attempt==1 and "" or "s", status)
    end
    MessageBox({ title="Session Complete", message=table.concat(lines,"\n"),
        display_handle=display, buttons={"OK"} })
end

-- Browse fixture_log.json from the console. ★ marks best values per fixture/kelvin.
local function show_fixture_history(display, data_dir)
    local sep = "/"
    pcall(function() sep = GetPathSeparator() end)
    local path = data_dir..sep.."fixture_log.json"

    local records = {}
    local f = io.open(path,"r")
    if f then
        local content = f:read("*a"); f:close()
        local skipped, errors
        records, skipped, errors = fixture_db.json_parse_db_array(content)
        if skipped and skipped > 0 then
            MessageBox({ title="Fixture History", message=string.format(
                "Warning: %d malformed record(s) skipped in fixture_log.json.", skipped),
                display_handle=display, buttons={"OK"} })
        end
    end

    if #records==0 then
        MessageBox({ title="Fixture History", message="No fixture measurements logged yet.\n\nCalibrate some fixtures first.",
            display_handle=display, buttons={"OK"} })
        return
    end

    -- Build sorted list of unique make+model combinations
    local fixtures, seen = {}, {}
    for _, rec in ipairs(records) do
        local key=(rec.make or "?").."|"..(rec.model or "?")
        if not seen[key] then
            seen[key]=true
            fixtures[#fixtures+1]={make=rec.make, model=rec.model}
        end
    end

    -- Prompt for search term
    local list_str = {}
    for _, fx in ipairs(fixtures) do
        list_str[#list_str+1]=(fx.make or "?").." "..(fx.model or "?")
    end
    local search_r = MessageBox({ title="Fixture History",
        message=string.format("Logged fixtures (%d):\n\n%s\n\nEnter make/model to view (or part of the name):",
            #fixtures, table.concat(list_str,"\n")),
        display_handle=display, input=true, buttons={"Search","Cancel"} })
    if search_r==nil or search_r==2 then return end
    local search = tostring(search_r):match("^%s*(.-)%s*$"):lower()

    -- Filter records
    local matches={}
    for _, rec in ipairs(records) do
        local full=((rec.make or "").." "..(rec.model or "")):lower()
        if search=="" or full:find(search,1,true) then matches[#matches+1]=rec end
    end
    if #matches==0 then
        MessageBox({ title="Not Found", message="No records found for: "..search,
            display_handle=display, buttons={"OK"} })
        return
    end

    -- Group by kelvin
    local kelvin_groups, kelvin_order, seen_k = {}, {}, {}
    for _, rec in ipairs(matches) do
        local k=rec.kelvin or 0
        if not seen_k[k] then seen_k[k]=true; kelvin_order[#kelvin_order+1]=k end
        if not kelvin_groups[k] then kelvin_groups[k]={} end
        kelvin_groups[k][#kelvin_groups[k]+1]=rec
    end
    table.sort(kelvin_order)

    local hdr_rec = matches[1]
    local hdr = string.format("%s %s", hdr_rec.make or "?", hdr_rec.model or "?")

    for _, k in ipairs(kelvin_order) do
        local entries = kelvin_groups[k]
        local lines = {
            string.format("%s @ %dK — %d measurement%s\n",
                hdr, k, #entries, #entries==1 and "" or "s"),
            string.format("%-10s  %-12s  %-6s %-6s %-6s %s",
                "Date","Contributor","CRI","R9","TLCI","Duv"),
            ("-"):rep(54),
        }
        for _, rec in ipairs(entries) do
            local function fv(v, best)
                if v==nil then return "  -- " end
                return string.format("%3d%s", v, best and STAR or " ")
            end
            local duv_s = rec.duv~=nil
                and string.format("%+.3f%s", rec.duv, rec.best_duv and STAR or " ")
                or "   --"
            lines[#lines+1]=string.format("%-10s  %-12s  %-6s%-6s%-6s %s",
                rec.date or "?", rec.contributor or "?",
                fv(rec.cri, rec.best_cri), fv(rec.r9, rec.best_r9),
                rec.tlci~=nil and fv(rec.tlci, rec.best_tlci) or "  -- ",
                duv_s)
        end
        lines[#lines+1]="\n"..STAR.." = best measurement for this fixture/kelvin"
        MessageBox({ title=string.format("Fixture History – %s @ %dK", hdr, k),
            message=table.concat(lines,"\n"), display_handle=display, buttons={"OK"} })
    end
end

--------------------------------------------------------------------------------
-- SECTION 2c: BRIDGE NETWORKING → lua/bridge_client.lua
--
-- GrandMA3 Lua does NOT support io.popen() / os.execute() / curl.
-- HTTP/1.0 over LuaSocket TCP is handled in bridge_client.lua.
--------------------------------------------------------------------------------

format_bridge_error = function(err_result, config)
    if type(err_result) == "string" then return err_result end
    if not err_result or type(err_result) ~= "table" then
        return "Unknown bridge error"
    end
    local kind = err_result.kind or "unknown"
    local msg  = err_result.message or "Unknown error"
    local hint = err_result.hint
    local ip   = config and config.bridge_ip or "?"

    if kind == "unauthorized" then
        return "Check bridge_api_key in config.json matches Pi BRIDGE_API_KEY"
            .. (hint and ("\n\n" .. hint) or "")
    end
    if kind == "connection" then
        return string.format("Cannot reach bridge at %s\n\n%s", ip, msg)
    end
    if kind == "timeout" or err_result.http_status == 504 then
        return "Meter did not respond in time"
            .. (hint and ("\n\n" .. hint) or "")
    end
    if kind == "meter_unavailable" or err_result.http_status == 503 then
        return "Meter not connected — check USB"
            .. (hint and ("\n\n" .. hint) or "")
    end
    if kind == "busy" or err_result.http_status == 409 then
        return "Measurement already in progress"
            .. (hint and ("\n\n" .. hint) or "")
    end
    if kind == "validation" or kind == "malformed" then
        return msg
    end
    return msg .. (hint and ("\n\n" .. hint) or "")
end

bridge_fetch_measurement = function(config)
    local result = bridge_client.fetch_measurement(config)
    if result.ok then return result.data end
    return nil, format_bridge_error(result, config)
end

local function bridge_check_status(config)
    if not config or not config.bridge_ip or config.bridge_ip == "" then
        return false, false, nil, false, false, false, false, nil
    end
    local result = bridge_client.check_status(config)
    if not result.ok then
        return false, false, nil, false, false, false, false, nil
    end
    local d = result.data
    return true, d.connected, d.meter, d.device_configured, d.protocol_captured,
           d.trigger_discovered, d.auth_required, d.last_error
end

_run_trigger_discovery = function(display, config)
    local result = bridge_client.learn_trigger(config)
    local lt_body = result.ok and result.body or ""
    local lt_ok  = result.ok and lt_body:find('"success"%s*:%s*true') ~= nil
    local lt_hex = lt_body:match('"trigger_cmd_hex"%s*:%s*"([^"]+)"') or "?"

    if lt_ok then
        MessageBox({
            title   = "Remote Trigger Found",
            message = string.format(
                "Full remote trigger discovered (command: 0x%s).\n\n"
                .."Bridge is now fully hands-free \xe2\x80\x93 measurements\n"
                .."start automatically without pressing any button.",
                lt_hex:upper()),
            display_handle = display,
            buttons = {"OK"},
        })
    else
        local lt_err = format_bridge_error(result, config)
        if result.ok and lt_body ~= "" then
            lt_err = lt_body:match('"error"%s*:%s*"([^"]+)"') or lt_err
        end
        MessageBox({
            title   = "Trigger Not Found",
            message = string.format(
                "Could not auto-discover the remote trigger.\n\n"
                .."Error: %s\n\n"
                .."Bridge will use physical button press mode:\n"
                .."the operator presses MEASURE on the C-7000\n"
                .."and the bridge captures the result.\n\n"
                .."You can retry from Bridge Status at any time,\n"
                .."or see the README for the Wireshark fallback.", lt_err),
            display_handle = display,
            buttons = {"OK"},
        })
    end
end

show_bridge_status = function(display, config)
    if not config or not config.bridge_ip or config.bridge_ip == "" then
        MessageBox({
            title   = "Bridge Status",
            message = "No bridge configured.\n\n"
                    .."Add bridge_ip and bridge_port to config.json\n"
                    .."to enable remote measurement.\n\n"
                    .."Example:\n"
                    ..'  "bridge_ip":   "192.168.1.50",\n'
                    ..'  "bridge_port": 8765',
            display_handle = display,
            buttons = {"OK"},
        })
        return
    end

    local reachable, connected, meter, dev_cfg, proto_cap, trigger_disc,
          auth_required, last_error = bridge_check_status(config)

    if not reachable then
        MessageBox({
            title   = "Bridge Unreachable",
            message = string.format(
                "Cannot connect to bridge at %s:%d\n\n"
                .."Check:\n"
                .."  \xe2\x80\xa2 Bridge Pi is powered and on the network\n"
                .."  \xe2\x80\xa2 IP in config.json is correct\n"
                .."  \xe2\x80\xa2 Bridge service is running\n\n"
                .."From the Pi terminal: curl http://%s:%d/status",
                config.bridge_ip, config.bridge_port or 8765,
                config.bridge_ip, config.bridge_port or 8765),
            display_handle = display,
            buttons = {"OK"},
        })
        return
    end

    local auth_line
    if auth_required then
        if config.bridge_api_key and config.bridge_api_key ~= "" then
            auth_line = "Auth:     Required (key configured)"
        else
            auth_line = "Auth:     Required \xe2\x80\x93 add bridge_api_key to config.json"
        end
    else
        auth_line = "Auth:     Not required"
    end
    local err_line = (last_error and last_error ~= "")
        and string.format("Last err: %s\n", last_error) or ""

    local needs_setup = not dev_cfg or not proto_cap
    local msg = string.format(
        "Bridge: %s:%d\n\n"
        .."Meter:    %s\n"
        .."Status:   %s\n"
        .."%s"
        .."%s"
        .."Device:   %s\n"
        .."Protocol: %s\n"
        .."Trigger:  %s",
        config.bridge_ip, config.bridge_port or 8765,
        meter or "C-7000",
        connected    and "Connected"             or "Not connected",
        auth_line .. "\n",
        err_line,
        dev_cfg      and "Configured"            or "Not configured \xe2\x80\x93 run Setup",
        proto_cap    and "Captured"              or "Not captured \xe2\x80\x93 run Setup",
        trigger_disc and "Remote (hands-free)"   or "Physical button required")

    if needs_setup then
        local r = MessageBox({
            title   = "Bridge Status",
            message = msg .. "\n\nRun the setup wizard to configure?",
            display_handle = display,
            buttons = {"Run Setup", "Close"},
        })
        if r == 1 then run_bridge_setup(display, config) end
    elseif not trigger_disc then
        local r = MessageBox({
            title   = "Bridge Status \xe2\x80\x93 Ready (button mode)",
            message = msg
                    .. "\n\nBridge is ready. Measurements require pressing MEASURE\n"
                    .. "on the C-7000.\n\n"
                    .. "Discover the remote trigger for fully hands-free operation?",
            display_handle = display,
            buttons = {"Discover Remote Trigger", "Close"},
        })
        if r == 1 then
            _run_trigger_discovery(display, config)
        end
    else
        MessageBox({
            title   = "Bridge Status \xe2\x80\x93 Fully Ready",
            message = msg .. "\n\nBridge is fully hands-free and ready.",
            display_handle = display,
            buttons = {"OK"},
        })
    end
end

run_bridge_setup = function(display, config)
    local step1 = MessageBox({
        title   = "Bridge Setup \xe2\x80\x93 Step 1: Discover",
        message = "The bridge will scan the USB bus on the Pi\n"
                .."for a connected Sekonic meter.\n\n"
                .."Make sure the C-7000 is plugged into the Pi via USB.",
        display_handle = display,
        buttons = {"Scan for Meter", "Cancel"},
    })
    if step1 ~= 1 then return end

    local disc_result = bridge_client.discover(config)
    if not disc_result.ok then
        MessageBox({
            title   = "Setup Failed",
            message = string.format("Could not reach bridge.\n\n%s",
                format_bridge_error(disc_result, config)),
            display_handle = display,
            buttons = {"OK"},
        })
        return
    end
    local disc_body = disc_result.body

    local disc_ok  = disc_body:find('"configured"%s*:%s*true')  ~= nil
    local disc_mfr = disc_body:match('"manufacturer"%s*:%s*"([^"]+)"') or "Unknown"
    local disc_prd = disc_body:match('"product"%s*:%s*"([^"]+)"')      or "Unknown"
    local disc_vid = disc_body:match('"vendor_id"%s*:%s*"([^"]+)"')    or "?"
    local disc_pid = disc_body:match('"product_id"%s*:%s*"([^"]+)"')   or "?"

    if not disc_ok then
        MessageBox({
            title   = "No Device Found",
            message = "No Sekonic meter found on USB.\n\n"
                    .."Check:\n"
                    .."  \xe2\x80\xa2 C-7000 is connected to the Pi via USB\n"
                    .."  \xe2\x80\xa2 USB cable is working (try another)\n"
                    .."  \xe2\x80\xa2 Pi has USB power",
            display_handle = display,
            buttons = {"OK"},
        })
        return
    end

    local step2 = MessageBox({
        title   = "Bridge Setup \xe2\x80\x93 Step 2: Verify",
        message = string.format(
            "Meter found on USB:\n\n"
            .."  %s %s\n"
            .."  VID=%s  PID=%s\n\n"
            .."Next: take a test measurement to verify the connection.\n\n"
            .."For the C-7000 this triggers automatically \xe2\x80\x93\n"
            .."no button press needed.\n\n"
            .."For other meters: press MEASURE within 30 s\n"
            .."if the bridge does not respond automatically.",
            disc_mfr, disc_prd, disc_vid, disc_pid),
        display_handle = display,
        buttons = {"OK \xe2\x80\x93 Test Measurement", "Cancel"},
    })
    if step2 ~= 1 then return end

    local cap_result = bridge_client.capture(config)
    if not cap_result.ok then
        MessageBox({
            title   = "Capture Failed",
            message = string.format("Bridge returned an error.\n\n%s",
                format_bridge_error(cap_result, config)),
            display_handle = display,
            buttons = {"OK"},
        })
        return
    end
    local cap_body = cap_result.body

    local cap_ok    = cap_body:find('"success"%s*:%s*true')           ~= nil
    local cap_cct   = tonumber(cap_body:match('"cct"%s*:%s*(%d+)'))
    local cap_raw   = cap_body:match('"raw_hex"%s*:%s*"([^"]+)"')     or ""
    local cap_proto = cap_body:find('"protocol_captured"%s*:%s*true') ~= nil

    if not cap_ok then
        local cap_err = cap_body:match('"error"%s*:%s*"([^"]+)"') or "unknown"
        MessageBox({
            title   = "Verification Failed",
            message = string.format(
                "No measurement received.\n\nError: %s\n\n"
                .."Check that the C-7000 is plugged in and powered.\n"
                .."For other meters: try pressing MEASURE during the window.", cap_err),
            display_handle = display,
            buttons = {"OK"},
        })
        return
    end

    if cap_proto and cap_cct then
        MessageBox({
            title   = "Capture Complete",
            message = string.format(
                "Response format captured!\n\n"
                .."Test measurement: CCT = %dK\n"
                .."Raw data: %s\xe2\x80\xa6\n\n"
                .."Bridge can now receive measurements\n"
                .."when MEASURE is pressed on the C-7000.",
                cap_cct, cap_raw:sub(1, 20)),
            display_handle = display,
            buttons = {"OK"},
        })
    else
        MessageBox({
            title   = "Captured \xe2\x80\x93 Manual Step Needed",
            message = string.format(
                "Raw data captured from C-7000:\n\n"
                .."%s\xe2\x80\xa6\n\n"
                .."Auto-parse did not match a known pattern.\n"
                .."See README: update _parse() in\n"
                .."meter_c7000_bulk.py on the Pi.",
                cap_raw:sub(1, 48)),
            display_handle = display,
            buttons = {"OK"},
        })
        return
    end

    local step3 = MessageBox({
        title   = "Bridge Setup \xe2\x80\x93 Step 3: Remote Trigger",
        message = "Optional: discover the remote trigger command.\n\n"
                .."When found, the bridge can start measurements\n"
                .."automatically \xe2\x80\x93 no button press required.\n\n"
                .."The bridge will probe candidate USB commands\n"
                .."(takes up to 2 minutes).\n\n"
                .."Click 'Discover' to start, or 'Skip' to use\n"
                .."physical button press mode instead.",
        display_handle = display,
        buttons = {"Discover Remote Trigger", "Skip"},
    })
    if step3 == 1 then
        _run_trigger_discovery(display, config)
    else
        MessageBox({
            title   = "Setup Complete",
            message = "Bridge is configured and ready.\n\n"
                    .."Measurements require pressing MEASURE on the C-7000.\n\n"
                    .."You can run 'Discover Remote Trigger' from\n"
                    .."Bridge Status at any time to enable hands-free mode.",
            display_handle = display,
            buttons = {"OK"},
        })
    end
end

--------------------------------------------------------------------------------
-- SECTION 3b: FIXTURE CAPABILITY DETECTION (via MA3 Patch API)
--
-- io.popen() and os.execute() are NOT available in GrandMA3 Lua, so GDTF files
-- cannot be extracted with unzip. Instead, capabilities are read from the MA3
-- Patch API: DataPool → Groups → Members[0] → FixtureType → DMXModes.
-- GrandMA3 has already parsed all GDTF data — we just query it through the API.
--
-- Note: has_color_wheel_filters (specific slot names like "1/4 CTO") cannot be
-- detected without reading GDTF XML. When a ColorWheel attribute is found we
-- set both has_color_wheel and has_color_wheel_filters = true as a safe default,
-- since a fixture with a colour wheel very likely has correction filter slots.
--------------------------------------------------------------------------------

-- Patch capabilities: patch_api.lua (Phase 6)
-- Fixture apply: fixture_apply.lua (Phase 6)

--------------------------------------------------------------------------------
-- SECTION 5: DATA LOGGING
--
-- io.popen() and os.execute() are NOT available in GrandMA3 Lua.
-- Path resolution uses GetPath(Enums.PathType.PluginLibrary) + GetPathSeparator().
-- Community upload to GitHub requires HTTPS; only lua.ftp (plain FTP) is
-- documented in the GrandMA3 Lua environment. Fixture data is therefore saved
-- locally only. To share data with the community, export fixture_log.json
-- manually and submit it via the project's GitHub page.
--
-- The data/ directory must exist inside the plugin folder (it is part of the
-- plugin package). No runtime directory creation is performed.
--------------------------------------------------------------------------------

-- Path/config helpers delegate to config.lua (Phase 6 D-105).
local function get_sep()
    return config_mod.get_sep()
end

local function get_plugin_dir()
    return config_mod.get_plugin_dir()
end

local function get_data_dir()
    return config_mod.get_data_dir()
end

local function load_config()
    return config_mod.load_config()
end

-- Append db_entry to local fixture_log.json using the append-only schema.
-- The data/ directory must exist (part of plugin installation).
local function save_fixture_log_local(db_entry)
    local ok = pcall(function()
        local sep  = get_sep()
        local path = get_data_dir() .. sep .. "fixture_log.json"
        local records = {}
        local rf = io.open(path, "r")
        if rf then records = select(1, fixture_db.json_parse_db_array(rf:read("*a"))); rf:close() end
        fixture_db.append_fixture_record(records, db_entry)
        fixture_db.sort_fixture_records(records)
        local wf = io.open(path, "w")
        if wf then wf:write(fixture_db.json_encode_db_array(records)); wf:close() end
    end)
    return ok
end

-- Save fixture measurement locally.
-- Community upload to GitHub is not available in GrandMA3 Lua (requires HTTPS;
-- only lua.ftp / plain FTP is documented). Export fixture_log.json manually
-- to share data with the community.
local function log_fixture_data(display, db_entry, config)
    if not db_entry.make or not db_entry.model then return end
    save_fixture_log_local(db_entry)
end

--------------------------------------------------------------------------------
-- SECTION 6: MAIN ENTRY POINT
--------------------------------------------------------------------------------

local function main(display, ...)
    local ok, err = pcall(function()

        -- ── Load config (needed for bridge status in menu) ────────────────
        local config = load_config()

        -- ── Main menu ─────────────────────────────────────────────────────
        local bridge_label = (config and config.bridge_ip and config.bridge_ip ~= "")
            and "Bridge Status"
            or  "Bridge Status (not configured)"
        local menu = MessageBox({
            title   = "SekonicCalibrator v0.5",
            message = "Lighttune – GrandMA3 Color Calibration\n\n"
                    .."Calibrate fixture groups using your\n"
                    .."Sekonic spectromaster (C-700, C-800, or C-7000).\n\n"
                    .."What would you like to do?",
            display_handle = display,
            buttons = {"Start Calibration","View Fixture History",bridge_label,"Cancel"},
        })
        if menu==nil or menu==4 then return end

        -- data_dir is provided by get_data_dir(); no mkdir needed –
        -- the data/ directory must exist as part of plugin installation.
        local data_dir = get_data_dir()

        if menu==2 then
            show_fixture_history(display, data_dir)
            return
        end

        if menu==3 then
            show_bridge_status(display, config)
            return
        end

        -- ── Calibration ───────────────────────────────────────────────────
        local session_goals = get_session_goals(display)
        if not session_goals then return end

        local session_log = {}

        -- Load local fixture records for pre-fill and session updates
        local fixture_records = {}
        do
            local sep = get_sep()
            local f = io.open(data_dir..sep.."fixture_log.json","r")
            if f then fixture_records=select(1, fixture_db.json_parse_db_array(f:read("*a"))); f:close() end
        end

        -- ── Outer loop: group by group ────────────────────────────────────
        repeat
            local group = get_group_input(display)
            if not group then break end

            local fixture_make, fixture_model = get_fixture_model_input(display, group)

            -- Read fixture capabilities from MA3 Patch API (nil = no data available).
            -- io.popen() / unzip are not available in GrandMA3 Lua, so GDTF files
            -- cannot be read directly. Capabilities are queried from the MA3 patch
            -- object which already has all GDTF attribute data parsed in memory.
            local caps = patch_api.read_capabilities_from_patch(group)

            -- Inject manufacturer-rated CRI into session_goals for context in measurement prompts
            session_goals.gdtf_cri = caps and caps.gdtf_cri or nil

            -- Look up historical data for pre-fill / pre-apply
            local hist = (fixture_make and fixture_model)
                and fixture_db.find_best_for_fixture(fixture_records, fixture_make, fixture_model, session_goals.cct)
                or nil

            -- Pre-apply best known correction before first measurement
            if hist then
                local tx, ty, ref_date = apply_historical_prefill(display, group, hist, session_goals)
                if tx then
                    local result = fixture_apply.calibrate_group(group, tx, ty)
                    if result.success then
                        MessageBox({ title="Pre-applied",
                            message=string.format(
                                "Best known correction applied to Group %s.\n"
                                .."Data from: %s\n\nNow take your first Sekonic reading.",
                                group, ref_date or "prior session"),
                            display_handle=display, buttons={"OK"} })
                    end
                end
            end

            local attempt         = 0
            local last_measured   = nil
            local last_correction = nil
            local applied_once    = false

            -- ── Inner loop: re-measure until happy ────────────────────────
            -- Bridge mode: auto-loops until goals met or 3 cycles exhausted.
            -- Manual mode: existing ask_group_done() behaviour unchanged.
            -- MTR-05: auto-loop up to 3 remote cycles per group (D-86–D-90)
            local MAX_AUTO_ATTEMPTS = 3
            local bridge_active = config and config.bridge_ip
                                          and config.bridge_ip ~= ""
                                          and session_goals.meter == METER_C7000
            local loop_done     = false
            local loop_count    = 0  -- cycles in the current "run"
            local user_manual   = false  -- true once user switches to manual

            repeat
                attempt = attempt + 1

                local measured, used_bridge

                if bridge_active and not user_manual and attempt > 1 then
                    -- Auto-trigger: call bridge directly, no choice dialog
                    local m, err = bridge_fetch_measurement(config)
                    if m then
                        used_bridge = true
                        -- Brief confirmation before assessment
                        local tlci_line = m.tlci
                            and string.format("  TLCI: %d\n", m.tlci) or ""
                        local conf = MessageBox({
                            title   = string.format(
                                "Auto-Measurement \xe2\x80\x93 Attempt %d", attempt),
                            message = string.format(
                                "Bridge measurement:\n\n"
                                .."  CCT : %dK\n  Duv : %+.4f\n"
                                .."  CRI : %d\n  R9  : %d\n%s\n"
                                .."Continue with these values?",
                                m.cct, m.duv, m.cri, m.r9, tlci_line),
                            display_handle = display,
                            buttons = {"Accept", "Enter Manually", "Cancel"},
                        })
                        if conf == nil or conf == 3 then
                            loop_done = true
                        elseif conf == 2 then
                            user_manual = true  -- switch to manual for remainder
                            measured, used_bridge =
                                get_measurement_params(display, attempt, session_goals, hist, config)
                        else
                            measured = m
                        end
                    else
                        -- Bridge error during auto-loop
                        local r = MessageBox({
                            title   = string.format("Bridge Error \xe2\x80\x93 Attempt %d", attempt),
                            message = string.format(
                                "Auto-measurement failed:\n  %s\n\nWhat would you like to do?",
                                tostring(err)),
                            display_handle = display,
                            buttons = {"Retry Remote", "Enter Manually", "Cancel"},
                        })
                        if r == nil or r == 3 then
                            loop_done = true
                        elseif r == 2 then
                            user_manual = true
                            measured, used_bridge =
                                get_measurement_params(display, attempt, session_goals, hist, config)
                        else
                            attempt = attempt - 1  -- retry, don't count this attempt
                        end
                    end
                else
                    -- First attempt or manual mode: normal measurement dialog
                    measured, used_bridge =
                        get_measurement_params(display, attempt, session_goals, hist, config)
                    -- If user chose manual entry when bridge was available, stay manual
                    if bridge_active and not used_bridge then user_manual = true end
                end

                if loop_done then break end
                if not measured then loop_done = true; break end
                last_measured = measured

                local correction = color_math.get_correction(
                    session_goals.cct, session_goals.duv, measured.cct, measured.duv)
                last_correction = correction

                -- ── Bridge auto-loop path ─────────────────────────────────
                if bridge_active and not user_manual then
                    loop_count = loop_count + 1

                    if goal_eval.goals_met(measured, session_goals) then
                        -- All goals achieved – show success and finish this group
                        MessageBox({
                            title   = string.format("Goals Met \xe2\x80\x93 Group %s", group),
                            message = string.format(
                                "All goals achieved after %d measurement%s!\n\n"
                                .."CRI: %d  R9: %d%s\n"
                                .."CCT: %dK  Duv: %+.4f",
                                attempt, attempt == 1 and "" or "s",
                                measured.cri, measured.r9,
                                measured.tlci
                                    and string.format("  TLCI: %d", measured.tlci) or "",
                                measured.cct, measured.duv),
                            display_handle = display,
                            buttons = {"Next Group"},
                        })
                        loop_done = true
                    else
                        -- Goals not yet met: show assessment, apply correction
                        local apply = show_assessment(
                            display, group, session_goals, measured, correction, attempt, caps)
                        if apply then
                            local result = fixture_apply.calibrate_group(
                                group, correction.target_x, correction.target_y)
                            if result.success then
                                applied_once = true
                                -- Suppress "re-measure" prompt; next measurement is automatic
                            else
                                show_result(display, false, group,
                                    result.method, result.error_msg)
                            end
                        end

                        if loop_count >= MAX_AUTO_ATTEMPTS then
                            -- Stuck: ask operator what to do
                            local r = MessageBox({
                                title   = string.format(
                                    "Group %s \xe2\x80\x93 Stuck after %d attempts",
                                    group, MAX_AUTO_ATTEMPTS),
                                message = string.format(
                                    "After %d measurements goals are still not met.\n\n"
                                    .."Check the hints in the last assessment.\n"
                                    .."Physical gels or fixture limits may apply.\n\n"
                                    .."What would you like to do?",
                                    MAX_AUTO_ATTEMPTS),
                                display_handle = display,
                                buttons = {"Accept & Move On", "Try Again", "Skip Group"},
                            })
                            if r == 1 then
                                loop_done = true          -- accept current results
                            elseif r == 3 then
                                last_measured = nil       -- skip: no DB entry
                                loop_done = true
                            else
                                loop_count = 0            -- try again: reset cycle counter
                            end
                        end
                        -- If not done, loop continues → next attempt auto-triggers bridge
                    end

                -- ── Manual mode path ─────────────────────────────────────
                else
                    local apply = show_assessment(
                        display, group, session_goals, measured, correction, attempt, caps)
                    if apply then
                        local result = fixture_apply.calibrate_group(
                            group, correction.target_x, correction.target_y)
                        show_result(display, result.success, group,
                            result.method, result.error_msg)
                        if result.success then applied_once = true end
                    end
                    loop_done = ask_group_done(display, group, attempt)
                end

            until loop_done
            -- ──────────────────────────────────────────────────────────────

            if last_measured then
                local db_entry = {
                    make        = fixture_make,
                    model       = fixture_model,
                    kelvin      = session_goals.cct,
                    date        = os.date("%Y-%m-%d"),
                    contributor = config and config.github_username or "local",
                    cct         = last_measured.cct,
                    duv         = last_measured.duv,
                    cri         = last_measured.cri,
                    r9          = last_measured.r9,
                    tlci        = last_measured.tlci,
                }
                log_fixture_data(display, db_entry, config)

                -- Keep in-memory records current for subsequent groups
                if fixture_make and fixture_model then
                    fixture_db.append_fixture_record(fixture_records, db_entry)
                end

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

        show_session_summary(display, session_log, session_goals)
    end)

    if not ok then
        MessageBox({ title="Unexpected Error",
            message="An unexpected error occurred:\n\n"..tostring(err)
                  .."\n\nPlease report this to the Lighttune project.",
            display_handle=display, buttons={"OK"} })
    end
end

return main
