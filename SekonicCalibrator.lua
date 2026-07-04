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
-- PLUGIN FOLDER PATH RESOLUTION
--------------------------------------------------------------------------------
-- GetPath(Enums.PathType.PluginLibrary) returns GrandMA3's own internal
-- shared resource folder (confirmed on a real console: it resolved to
-- ".../gma3_2.3.2/shared/resource/lib_plugins", causing "cannot open
-- .../lua/color_math.lua" at load time) — NOT the user's installed plugin
-- folder. debug.getinfo(1,"S").source is also unusable here: GrandMA3 loads
-- plugin components via load() with a synthetic chunk name
-- ("SekonicCalibrator@SekonicCalibrator.lua"), not a real file path. The
-- install location is fixed by this plugin's own install instructions
-- (package-plugin.sh / README), so construct it directly instead of
-- trusting either API for it.

-- Returns the OS path separator using the GrandMA3 GetPathSeparator() API.
local function get_sep()
    local sep = "/"
    pcall(function() sep = GetPathSeparator() end)
    return sep
end

-- Returns true when `dir` looks like the SekonicCalibrator plugin root.
local function plugin_root_exists(dir)
    if not dir or dir == "" then return false end
    local marker = dir .. get_sep() .. "SekonicCalibrator.lua"
    local ok, exists = pcall(function()
        if FileExists then return FileExists(marker) end
        local f = io.open(marker, "r")
        if f then f:close(); return true end
        return false
    end)
    return ok and exists
end

-- Returns the path to the SekonicCalibrator plugin root directory.
local function get_plugin_dir()
    local sep = get_sep()
    local candidates = {}

    local function add(path)
        if path and path ~= "" then candidates[#candidates + 1] = path end
    end

    pcall(function()
        local plugins = GetPath and GetPath("plugins")
        if plugins and plugins ~= "" then
            add(plugins .. sep .. "SekonicCalibrator")
        end
    end)

    local host = "Linux"
    pcall(function() host = HostOS() end)
    if host == "Windows" then
        local appdata = (os.getenv and os.getenv("APPDATA"))
                     or "C:\\Users\\Default\\AppData\\Roaming"
        add(appdata .. "\\MALightingTechnology\\gma3_library\\datapools\\plugins\\SekonicCalibrator")
    else
        local home = (os.getenv and os.getenv("HOME")) or "/root"
        add(home .. sep .. "MALightingTechnology" .. sep
            .. "gma3_library" .. sep .. "datapools" .. sep .. "plugins" .. sep .. "SekonicCalibrator")
    end

    for _, path in ipairs(candidates) do
        if plugin_root_exists(path) then return path end
    end
    return candidates[1] or (sep .. "SekonicCalibrator")
end

--------------------------------------------------------------------------------
-- DOMAIN MODULE LOADER (Phase 2 — loadfile from plugin lua/, no require cache)
--------------------------------------------------------------------------------

local function load_domain_modules()
    local plugin_dir = get_plugin_dir()
    package.path = plugin_dir .. "/lua/?.lua;" .. package.path

    -- Always load from the plugin's lua/ folder via loadfile. Generic names
    -- like "goals" collide with GrandMA3's own package.loaded cache — require()
    -- can succeed with a stale or unrelated module that lacks our exports
    -- (live crash: error_score nil at line 1965 after a bridge measurement).
    local function try_require(name)
        local path = plugin_dir .. get_sep() .. "lua" .. get_sep() .. name .. ".lua"
        local chunk, err = loadfile(path)
        if not chunk then
            error(string.format("module %s (%s): %s", name, path, tostring(err)))
        end
        local mod = chunk()
        if type(mod) ~= "table" then error("module " .. name .. " must return a table") end
        return mod
    end

    return {
        color_math     = try_require("color_math"),
        fixture_db     = try_require("fixture_db"),
        goals          = try_require("goals"),
        bridge_client  = try_require("bridge_client"),
        crash_log      = try_require("crash_log"),
        gdtf_caps      = try_require("gdtf_caps"),
    }
end

-- If module load fails during plugin import, GM3 reports
-- "no reference to main function found" unless we return an entry point anyway.
local color_math, fixture_db, goals, bridge_client, crash_log, gdtf_caps
local QUALITY, GOAL_MAX, GOAL_MIN, GOAL_SKIP
local goals_met, goal_status_str, error_score, has_improved, update_stagnation, is_stagnated
local IMPROVEMENT_EPSILON, CCT_GOAL_TOLERANCE

-- Forward declarations (bridge helpers defined after load_config near file end).
local bridge_configured, push_fixture_log_to_bridge, open_fixture_history_in_bridge

local modules_ok, modules_err = pcall(function()
    local domain = load_domain_modules()
    color_math     = domain.color_math
    fixture_db     = domain.fixture_db
    goals          = domain.goals
    bridge_client  = domain.bridge_client
    crash_log      = domain.crash_log
    gdtf_caps      = domain.gdtf_caps
    QUALITY     = goals.QUALITY
    GOAL_MAX    = goals.GOAL_MAX
    GOAL_MIN    = goals.GOAL_MIN
    GOAL_SKIP   = goals.GOAL_SKIP
    goals_met        = goals.goals_met
    goal_status_str  = goals.goal_status_str
    error_score       = goals.error_score
    has_improved      = goals.has_improved
    update_stagnation = goals.update_stagnation
    is_stagnated       = goals.is_stagnated
    IMPROVEMENT_EPSILON = goals.IMPROVEMENT_EPSILON
    CCT_GOAL_TOLERANCE  = goals.CCT_GOAL_TOLERANCE
    if type(error_score) ~= "function" or type(has_improved) ~= "function"
        or type(update_stagnation) ~= "function" or type(is_stagnated) ~= "function" then
        error("goals module is missing error_score/has_improved/update_stagnation — reinstall lua/goals.lua")
    end
end)

if not modules_ok then
    return function(display)
        local dir = get_plugin_dir()
        local msg = string.format(
            "SekonicCalibrator could not load its Lua modules:\n\n%s\n\n"
            .. "Plugin dir: %s\n\n"
            .. "Fix:\n"
            .. "  1. Run ./package-plugin.sh --install\n"
            .. "  2. In Plugin Pool: Delete the old SekonicCalibrator entry\n"
            .. "  3. Import plugin.xml again (GM3 1.6+ needs a fresh import after updates)",
            tostring(modules_err), tostring(dir))
        if Printf then Printf("Lighttune load error: " .. msg) end
        if Echo then
            Echo("Lighttune: SekonicCalibrator module load failed — see Command Line / System Monitor")
            for line in msg:gmatch("[^\r\n]+") do Echo(line) end
        end
    end
end

local function tracks_spectral_goal(goal)
    return goal and goal.mode ~= GOAL_SKIP
end

-- One-line summary of measured values, omitting metrics not tracked this session.
local function measured_metrics_summary(measured, goals)
    local parts = { string.format("CCT: %dK  Duv: %+.4f", measured.cct, measured.duv) }
    if tracks_spectral_goal(goals.cri) and measured.cri then
        parts[#parts + 1] = string.format("CRI: %d", measured.cri)
    end
    if tracks_spectral_goal(goals.r9) and measured.r9 then
        parts[#parts + 1] = string.format("R9: %d", measured.r9)
    end
    if tracks_spectral_goal(goals.tlci) and measured.tlci then
        parts[#parts + 1] = string.format("TLCI: %d", measured.tlci)
    end
    return table.concat(parts, "  ")
end

-- Echo multi-line status to System Monitor (readable; progress bar stays one line).
local function echo_lighttune_block(title, message)
    Echo("Lighttune: " .. tostring(title))
    if not message or message == "" then return end
    for line in tostring(message):gmatch("[^\r\n]+") do
        if line:match("%S") then Echo(line) end
    end
end

-- One-line summary for the progress bar (bar does not grow for multi-line text).
local function format_correction_summary_line(last_apply)
    if not last_apply or not last_apply.correction then return nil end
    local c = last_apply.correction
    local dk = c.delta_cct or 0
    local dk_s = dk > 0 and string.format("+%dK", dk)
        or dk < 0 and string.format("%dK", dk) or "on target"
    local xy = (last_apply.to_x and last_apply.to_y)
        and string.format(" xy (%.3f, %.3f)", last_apply.to_x, last_apply.to_y) or ""
    local method = last_apply.method and (" · " .. last_apply.method) or ""
    return string.format("Correction: %s, Duv %+.4f%s%s",
        dk_s, c.delta_duv or 0, xy, method)
end
-- Detailed correction recap (System Monitor only — not the progress overlay).
local function format_correction_fun_fact(last_apply)
    if not last_apply or not last_apply.correction then return "" end
    local c = last_apply.correction
    local dk_cct = c.delta_cct or 0
    local dk_duv = c.delta_duv or 0

    local dk_cct_s = dk_cct > 0 and string.format("+%dK", dk_cct)
        or dk_cct < 0 and string.format("%dK", dk_cct) or "0K"
    local dk_duv_s = dk_duv > 0 and string.format("+%.4f", dk_duv)
        or string.format("%.4f", dk_duv)

    local cct_hint = dk_cct > 0 and "cooler" or dk_cct < 0 and "warmer" or "on target"
    local duv_hint = dk_duv > 0 and "greener" or dk_duv < 0 and "toward magenta" or "neutral"

    local lines = {
        "Since your last reading we nudged this fixture:",
        string.format("  Gap we were closing: %s (%s), Duv %s (%s)",
            dk_cct_s, cct_hint, dk_duv_s, duv_hint),
    }
    if last_apply.to_x and last_apply.to_y then
        if last_apply.from_x and last_apply.from_y then
            lines[#lines + 1] = string.format(
                "  xy command: (%.4f, %.4f) → (%.4f, %.4f)",
                last_apply.from_x, last_apply.from_y, last_apply.to_x, last_apply.to_y)
        else
            lines[#lines + 1] = string.format(
                "  xy command set to: (%.4f, %.4f)",
                last_apply.to_x, last_apply.to_y)
        end
    end
    if last_apply.method then
        lines[#lines + 1] = string.format("  How: %s", last_apply.method)
    end
    local ch = last_apply.channels
    if ch then
        local parts = {}
        if ch.tint_changed then parts[#parts + 1] = string.format("Tint %.1f", ch.tint) end
        if ch.ctc_changed and ch.ctc_kelvin then
            parts[#parts + 1] = string.format("CTC %dK", math.floor(ch.ctc_kelvin + 0.5))
        end
        if ch.cto_changed  then parts[#parts + 1] = string.format("CTO %.1f", ch.cto) end
        if ch.ctb_changed  then parts[#parts + 1] = string.format("CTB %.1f", ch.ctb) end
        if ch.wheel_changed and ch.color_wheel_slot then
            parts[#parts + 1] = "Wheel \"" .. ch.color_wheel_slot .. "\""
        end
        if #parts > 0 then
            lines[#lines + 1] = "  Channels: " .. table.concat(parts, ", ")
        end
    end
    return table.concat(lines, "\n") .. "\n\n"
end

local function measurement_leadin(last_apply, attempt)
    if attempt <= 1 or not last_apply then return "" end
    return format_correction_fun_fact(last_apply)
end

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

-- v2: per-fixture closed-loop auto-correction safety limits.
-- MAX_STAGNANT: stop after this many score non-improvements OR when the last
-- three readings stay within STAGNANT_READING_CCT_K / STAGNANT_READING_DUV.
-- MAX_ATTEMPTS_HARD: absolute backstop regardless of the above, so a
-- fixture that keeps "improving" by a hair forever (or oscillating just
-- above the stagnation threshold) can't loop indefinitely.
local MAX_STAGNANT       = 3
local MAX_ATTEMPTS_HARD  = 12
local BRIDGE_AUTO_CONTINUE_SEC = 3

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
-- MessageBox ADAPTER
-- Every call site in this file uses a simplified dialog signature —
-- title / message / display_handle / buttons={"label", ...} / input=true —
-- and expects the return to be: nil (cancelled), a 1-based button index,
-- or (for input=true dialogs) the typed text when the FIRST button is
-- pressed, else that button's index (used as a cancel/skip sentinel).
--
-- The real grandMA3 global MessageBox() takes commands={{value=,name=},...}
-- and inputs={{name=,value=},...}, and returns {success=, result=, inputs=}.
-- (https://help.malighting.com/grandMA3/2.3/HTML/lua_objectfree_messagebox.html)
-- Without this adapter, every buttons={...} call above was silently ignored
-- by the real MessageBox (it has no "buttons" field), so popups rendered
-- with a title and message but NO buttons — stuck on screen with no way to
-- close them except Escape. Confirmed live on a running GrandMA3 onPC.
--
-- Shadow the native function with an adapter so every existing call site
-- below keeps working unchanged.
--------------------------------------------------------------------------------
local NativeMessageBox = MessageBox

local function MessageBox(opts)
    local commands
    if opts.buttons then
        commands = {}
        for i, label in ipairs(opts.buttons) do
            commands[i] = { value = i, name = label }
        end
    end

    local inputs
    if opts.input then
        inputs = { { name = "", value = "" } }
    end

    local ret = NativeMessageBox({
        title   = opts.title,
        message = opts.message,
        icon    = opts.icon,
        commands = commands,
        inputs   = inputs,
    })

    if not ret or not ret.success then return nil end

    if inputs then
        if ret.result == 1 then
            local text = ""
            for _, v in pairs(ret.inputs or {}) do text = v; break end
            return text
        end
        return ret.result
    end

    return ret.result
end

-- MA3 plugins run as coroutines; never busy-wait (freezes the whole console).
-- coroutine.yield MUST NOT be called inside pcall — it cannot cross the pcall
-- boundary and will silently skip, making every countdown instant.
local function yield_seconds(sec)
    if not sec or sec <= 0 then return end
    coroutine.yield(sec)
end

-- Bridge hands-free: echo full details to System Monitor; progress bar = one line + countdown.
-- GM3 progress bars do not grow for multi-line text (long text gets clipped by the bar).
local function auto_continue_pause(title, message, seconds, config, summary_line)
    seconds = seconds
        or (config and config.bridge_auto_continue_sec)
        or BRIDGE_AUTO_CONTINUE_SEC
    echo_lighttune_block(title, message)
    if seconds <= 0 then return end

    local bar_title = tostring(title):match("^[^\n]+") or tostring(title)
    if #bar_title > 72 then bar_title = bar_title:sub(1, 69) .. "…" end

    local handle
    local progress_ok = pcall(function()
        handle = StartProgress(bar_title)
        SetProgressRange(handle, 0, seconds)
    end)

    if not progress_ok or not handle then
        for i = seconds, 1, -1 do
            Echo(string.format("Continuing in %d s…", i))
            yield_seconds(1)
        end
        return
    end

    for remaining = seconds, 1, -1 do
        local bar_text = summary_line
            and string.format("%s  ·  %d s…", summary_line, remaining)
            or string.format("Continuing in %d s…", remaining)
        pcall(function()
            SetProgressText(handle, bar_text)
            SetProgress(handle, seconds - remaining)
        end)
        yield_seconds(1)
    end
    pcall(function() StopProgress(handle) end)
end

-- OK dialog, or auto-continue countdown when bridge hands-free mode is active.
local function ok_or_auto_continue(display, title, message, bridge_active, config, seconds, summary_line)
    if bridge_active then
        auto_continue_pause(title, message, seconds, config, summary_line)
        return
    end
    MessageBox({
        title = title,
        message = message,
        display_handle = display,
        buttons = {"OK"},
    })
end

--------------------------------------------------------------------------------
-- SECTION 3: UI HELPERS
-- Forward declarations for bridge functions (defined in Section 2c, below).
local format_bridge_error
local bridge_fetch_measurement
local bridge_check_status
local run_bridge_setup
local show_bridge_status
local _run_trigger_discovery
local preflight_bridge_check
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

-- v2: adds a Remote/Manual choice, mirroring the per-attempt measurement
-- dialog used later in the session -- previously the reference measurement
-- was ALWAYS manual entry even when a working bridge was configured,
-- forcing the operator to read the meter by eye and type it in for the one
-- measurement the whole session's targets are derived from.
local function get_reference_measurements(display, ref_group, meter, config)
    local bridge_ready = meter == METER_C7000
        and config and config.bridge_ip and config.bridge_ip ~= ""
        and select(1, bridge_check_status(config))

    if bridge_ready then
        local choice = MessageBox({
            title   = "Reference Measurement – "..ref_group,
            message = string.format(
                "Point the meter at '%s' and measure.\n\n"
                .."Bridge is reachable — trigger the reading remotely,\n"
                .."or enter the values by hand.",
                ref_group),
            display_handle = display,
            buttons = {"Measure via Bridge","Enter Manually","Cancel"},
        })
        if choice == nil or choice == 3 then return nil end
        if choice == 1 then
            local m, err = bridge_fetch_measurement(config)
            if m then
                MessageBox({ title="Reference Captured (Bridge)",
                    message=string.format("Reference group: %s\n\n  CCT: %dK\n  Duv: %+.4f (%s)",
                        ref_group, m.cct, m.duv, color_math.rate_duv(m.duv)),
                    display_handle=display, buttons={"OK"} })
                return { cct=m.cct, duv=m.duv }
            end
            MessageBox({ title="Bridge Measurement Failed",
                message="Falling back to manual entry:\n\n"..tostring(err),
                display_handle=display, buttons={"OK"} })
            -- fall through to manual entry below
        end
    end

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

-- v2: "Calibrate to target" now collects a LIST of Kelvin targets instead
-- of one -- a session can batch-calibrate the same fixture groups at, say,
-- 3200K, 4300K, and 5600K in one pass without re-running the plugin and
-- re-answering the meter/mode/quality-goal questions each time. The quality
-- goals (CRI/R9/TLCI) and Duv target apply across every Kelvin in the list.
-- "Match to reference" keeps a single target (the measured reference IS the
-- target -- there's no separate Kelvin to batch), returned as a one-item list
-- so the caller (main) can loop over cct_list uniformly either way.
local function get_session_goals(display, config, preset_meter)
    -- Meter model — skip prompt when the bridge already reports the connected meter
    local meter = preset_meter
    if not meter then
        local mc = MessageBox({
            title="Sekonic Meter Model",
            message="Which Sekonic meter are you using?\n\n"
                  .."  C-700 / C-800  – CCT, Duv, CRI, R9  (no TLCI)\n"
                  .."  C-7000         – CCT, Duv, CRI, R9, TLCI",
            display_handle=display, buttons={"C-700 / C-800","C-7000"} })
        if mc==nil then return nil end
        meter = (mc==1) and METER_C700 or METER_C7000
    end

    -- Calibration mode
    local mode_choice = MessageBox({
        title="Calibration Mode",
        message="Choose a calibration mode:\n\n"
              .."  Calibrate to target  – set one or more Kelvin targets;\n"
              .."                         all groups corrected to each\n\n"
              .."  Match to reference   – measure one reference group\n"
              .."                         first; all others matched to it",
        display_handle=display, buttons={"Calibrate to target","Match to reference"} })
    if mode_choice==nil then return nil end

    local cal_mode  = (mode_choice==1) and MODE_TARGET or MODE_REFERENCE
    local ref_group = nil
    local cct_list  = {}
    local duv

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
        local ref_meas = get_reference_measurements(display, ref_group, meter, config)
        if not ref_meas then return nil end
        duv = ref_meas.duv
        cct_list = { ref_meas.cct }
        MessageBox({ title="Reference Captured",
            message=string.format("Reference group: %s\n\n  CCT: %dK\n  Duv: %+.4f (%s)\n\nAll other groups will be matched to these values.",
                ref_group, ref_meas.cct, ref_meas.duv, color_math.rate_duv(ref_meas.duv)),
            display_handle=display, buttons={"OK"} })
    else
        repeat
            local ordinal = #cct_list == 0 and "" or string.format(" #%d", #cct_list + 1)
            local next_cct = get_number_input(display,"Target Color Temperature"..ordinal,
                string.format("Enter target CCT %s in Kelvin.\nRange: %d – %d\n\n"
                    .."Common values:\n  3200K  Tungsten\n  4300K  Fluorescent\n"
                    .."  5600K  Daylight\n  6500K  Overcast",
                    #cct_list == 0 and "" or ("#"..(#cct_list + 1)), CCT_MIN, CCT_MAX),
                CCT_MIN, CCT_MAX)
            if not next_cct then
                if #cct_list == 0 then return nil end
                break
            end
            table.insert(cct_list, next_cct)

            local more = MessageBox({ title="Batch Kelvin Targets",
                message=string.format(
                    "Targets so far: %s\n\n"
                    .."Add another Kelvin target to this session?\n"
                    .."(Each fixture group will be calibrated once per target.)",
                    table.concat((function()
                        local strs = {}
                        for _, k in ipairs(cct_list) do strs[#strs+1] = k.."K" end
                        return strs
                    end)(), ", ")),
                display_handle=display, buttons={"Add Another","Done"} })
            if more ~= 1 then break end
        until false

        local duv_choice = MessageBox({ title="Target Duv",
            message="Target Duv (green-magenta deviation) — applies to every Kelvin target:\n\n"
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
        cct_list=cct_list, duv=duv,
        cri=spectral.cri, r9=spectral.r9, tlci=spectral.tlci,
    }
end

local function parse_group_names(raw)
    local names = {}
    for part in tostring(raw):gmatch("[^,]+") do
        local v = part:match("^%s*(.-)%s*$")
        if v ~= "" then names[#names + 1] = v end
    end
    return names
end

-- Collect one or more fixture groups for the session (batch, like Kelvin targets).
-- Comma-separated names/numbers add several at once (e.g. "1, 3, Front Wash").
-- Returns an ordered list, or nil when cancelled before any group was entered.
local function get_group_list_input(display)
    local group_list = {}
    repeat
        local ordinal = #group_list == 0 and "" or string.format(" #%d", #group_list + 1)
        local prefix = #group_list > 0
            and string.format("Groups so far: %s\n\n", table.concat(group_list, ", "))
            or ""
        local added = nil
        for attempt = 1, 3 do
            local invalid = attempt > 1 and "Please enter at least one group.\n\n" or ""
            local r = MessageBox({
                title   = "Select Fixture Groups"..ordinal,
                message = prefix .. invalid
                    .. "Enter group number(s) or name(s) to calibrate:\n"
                    .. "(e.g.  1  |  Front Wash  |  1, 3, Back Wash)",
                display_handle = display,
                input = true,
                buttons = {"OK", "Cancel"},
            })
            if r == nil or r == 2 then
                if #group_list == 0 then return nil end
                added = false
                break
            end
            local parsed = parse_group_names(r)
            if #parsed > 0 then
                for _, g in ipairs(parsed) do
                    group_list[#group_list + 1] = g
                end
                added = true
                break
            end
        end
        if added == false then break end
        if not added then return nil end

        local more = MessageBox({
            title   = "Batch Groups",
            message = string.format(
                "Groups in this session: %s\n\n"
                .. "Add another fixture group?\n"
                .. "(Every group is calibrated at each Kelvin target.)",
                table.concat(group_list, ", ")),
            display_handle = display,
            buttons = {"Add Another", "Start Calibration"},
        })
        if more ~= 1 then break end
    until false
    return group_list
end

-- Extract manufacturer + model strings from a FixtureType handle.
-- GM3 property casing varies by version/library (Manufacturer vs manufacturer).
local function fixture_type_make_model(ft)
    if not ft then return nil, nil end
    local make, model
    pcall(function()
        make  = ft.Manufacturer or ft.manufacturer
        model = ft.Long or ft.long or ft.Name or ft.name
    end)
    if type(make)  == "string" and make  == "" then make  = nil end
    if type(model) == "string" and model == "" then model = nil end
    return make, model
end

-- Locate a fixture group in the DataPool by number or name.
local function find_group(group_name)
    local grp
    pcall(function()
        local dp = DataPool(); if not dp then return end
        local groups = dp.Groups or dp.groups; if not groups then return end
        local num = tonumber(group_name)
        if num then
            grp = groups:Child(num - 1)
            if not grp and groups[num] then grp = groups[num] end
        end
        if grp then return end
        local count = 0
        pcall(function() count = groups:Count() end)
        for i = 0, math.max(count - 1, 0) do
            local g = groups:Child(i)
            if g then
                local n = g.Name or g.name
                if n == group_name then grp = g; return end
            end
        end
    end)
    return grp
end

-- 1-based Groups pool index for an exact group name (e.g. "CAL", "UNCAL").
local function group_pool_index(group_name)
    if not group_name or group_name == "" then return nil end
    local idx
    pcall(function()
        local grp = find_group(group_name)
        if not grp then return end
        local dp = DataPool()
        if not dp then return end
        local groups = dp.Groups or dp.groups
        if not groups then return end
        local count = 0
        pcall(function() count = groups:Count() end)
        for i = 0, math.max(count - 1, 999) do
            if groups:Child(i) == grp then idx = i + 1; return end
        end
        for i = 1, 999 do
            if groups[i] == grp then idx = i; return end
        end
    end)
    return idx
end

-- 1-based Color preset index in pool `pool_type` for an exact preset name (e.g. "5000K").
local function find_color_preset_by_name(name, pool_type)
    if not name or name == "" then return nil end
    pool_type = pool_type or 4
    local idx
    pcall(function()
        if ObjectList then
            local objs = ObjectList(string.format('Preset %d."%s"', pool_type, name:gsub('"', '\\"')))
            if objs and objs[1] then
                local addr = tostring(objs[1].Addr or objs[1].addr or objs[1].Address or "")
                idx = tonumber(addr:match("%." .. pool_type .. "%.(%d+)"))
                if idx then return end
            end
        end
        local dp = DataPool()
        if not dp then return end
        local pool = dp.PresetPools and dp.PresetPools[pool_type]
        if not pool then return end
        for i = 1, 9999 do
            local p = pool[i]
            if not p then break end
            local n = p.Name or p.name
            if n == name then idx = i; return end
        end
    end)
    return idx
end

local function init_named_group_tracker(name)
    local idx = group_pool_index(name)
    return { created = idx ~= nil, idx = idx, name = name }
end

local function init_kelvin_preset_tracker(kelvin)
    local name = string.format("%dK", kelvin)
    local idx = find_color_preset_by_name(name)
    return { created = idx ~= nil, idx = idx, name = name, kelvin = kelvin }
end

-- Open System Monitor on a secondary display when available (AutoFit into next free area).
local function open_system_monitor_view(display_handle)
    local screen_arg = "Default"
    local target = nil
    pcall(function()
        local dc = GetDisplayCollect()
        if not dc then return end
        local best = 0
        for _, entry in pairs(dc) do
            if type(entry) == "table" and entry.INDEX then
                local n = tonumber(entry.INDEX) or 0
                if n > best then best = n end
            end
        end
        if best >= 2 then
            screen_arg = tostring(best)
            target = GetDisplayByIndex(best)
        end
    end)

    local window_names = { "WindowSystemMonitor", "SystemMonitor" }
    for _, wname in ipairs(window_names) do
        local cmd = string.format('Store ScreenContent %s "%s" /AutoFit', screen_arg, wname)
        local ok, feedback = pcall(function()
            if CmdIndirectWait then
                CmdIndirectWait(cmd, nil, target)
                return "OK"
            end
            return Cmd(cmd)
        end)
        if ok and (not feedback or tostring(feedback):find("OK") or feedback == true) then
            Echo(string.format(
                "Lighttune: System Monitor opened (display %s) — watch here for step-by-step output",
                screen_arg))
            crash_log.trace("info", "system_monitor_opened", { display = screen_arg, window = wname })
            return true
        end
    end
    Echo("Lighttune: could not auto-open System Monitor — add it manually (More → System Monitor)")
    crash_log.trace("warn", "system_monitor_open_failed", { display = screen_arg })
    return false
end

local function fixture_type_from_subfixture(sf_index)
    local make, model
    pcall(function()
        if not GetSubfixture then return end
        local sub = GetSubfixture(sf_index)
        if not sub then return end
        local fix = sub.fixture or sub.Fixture
        if not fix then return end
        make, model = fixture_type_make_model(fix.FixtureType or fix.fixturetype)
    end)
    return make, model
end

-- Read make/model from a group's first patched fixture.
-- Primary path: SelectionData → GetSubfixture (documented GM3 API).
-- Fallback: group Members → FixtureType (older path).
local function get_fixture_type_from_group(grp)
    if not grp then return nil, nil end
    local make, model

    pcall(function()
        local sel = grp.SelectionData or grp.selectiondata
        if not sel then return end
        for _, entry in ipairs(sel) do
            local sf = entry.sf_index or entry.SFIndex or entry.SfIndex
            if sf then
                make, model = fixture_type_from_subfixture(sf)
                if make and model then return end
            end
        end
    end)
    if make and model then return make, model end

    pcall(function()
        local members = grp.Members
        if not members or members:Count() == 0 then return end
        local fixture = members:Child(0)
        if not fixture then return end
        make, model = fixture_type_make_model(fixture.FixtureType or fixture.fixturetype)
    end)
    return make, model
end

-- Read make/model from the console's current fixture selection
-- (after Group is selected). Uses ObjectList and/or GetSubfixture.
local function get_fixture_type_from_selection()
    local make, model
    pcall(function()
        if not SelectionFirst then return end
        local fid = SelectionFirst()
        if not fid then return end

        if ObjectList then
            local objs = ObjectList("Fixture " .. tostring(fid))
            if objs and objs[1] then
                make, model = fixture_type_make_model(
                    objs[1].fixturetype or objs[1].FixtureType)
                if make and model then return end
            end
        end

        make, model = fixture_type_from_subfixture(fid)
    end)
    return make, model
end

-- Read fixture manufacturer + model from the MA3 patch for a group.
-- Never prompts — returns nil, nil when the desk has no usable type data.
local function get_fixture_model_from_desk(group_name)
    local make, model = get_fixture_type_from_group(find_group(group_name))
    if make and model then return make, model end
    return get_fixture_type_from_selection()
end

-- Patched fixture display name for a specific FID (e.g. "Key Front 01").
local function get_fixture_name_from_desk(fnum)
    if not fnum then return nil end
    local name
    pcall(function()
        if ObjectList then
            local objs = ObjectList("Fixture " .. tostring(fnum))
            if objs and objs[1] then
                name = objs[1].name or objs[1].Name
            end
        end
        if name and name ~= "" then return end
        if GetSubfixture then
            local sub = GetSubfixture(fnum)
            if sub then
                local fix = sub.fixture or sub.Fixture
                if fix then name = fix.name or fix.Name end
            end
        end
    end)
    if type(name) == "string" and name ~= "" then return name end
    return nil
end

-- ctx: { group, fnum, index, total, name, type_make, type_model, groups_index, groups_total }
local function format_fixture_context(ctx)
    if not ctx then return "" end
    local batch_line = (ctx.groups_total and ctx.groups_total > 1)
        and string.format("Group %d/%d\n", ctx.groups_index, ctx.groups_total) or ""
    local phase_line = (ctx.phase == "group")
        and "Pass: entire group\n"
        or (ctx.phase == "individual" and ctx.fnum)
            and string.format("Pass: individual fixture\n") or ""
    if not ctx.fnum then
        return string.format("%s%sGroup: %s\n\n", batch_line, phase_line, tostring(ctx.group or "?"))
    end
    local name_line = ctx.name and string.format("Name: %s\n", ctx.name) or ""
    local type_line = (ctx.type_make and ctx.type_model)
        and string.format("Type: %s %s\n", ctx.type_make, ctx.type_model) or ""
    return string.format(
        "%sFix %d/%d\nFixture #%d\n%s%sGroup: %s\n\n",
        batch_line, ctx.index, ctx.total, ctx.fnum, name_line, type_line, tostring(ctx.group))
end

local function with_fixture_context(ctx, message)
    local header = format_fixture_context(ctx)
    if header == "" then return message end
    return header .. message
end

local function fixture_context_title(ctx, base)
    if not ctx or not ctx.fnum then return base end
    return string.format("%s – Fix %d/%d", base, ctx.index, ctx.total)
end

local function fixture_label(ctx)
    if not ctx or not ctx.fnum then return tostring(ctx and ctx.group or "?") end
    local name = ctx.name and ("  " .. ctx.name) or ""
    return string.format("Fix %d/%d  Fixture #%d%s", ctx.index, ctx.total, ctx.fnum, name)
end

-- Show prior data and offer to pre-apply the best known correction.
-- Called before the first measurement of a group when hist ~= nil.
local function apply_historical_prefill(display, group, hist, goals)
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
            goals.cct, table.concat(lines,"\n")),
        display_handle=display,
        buttons={"Yes – Pre-apply","No – Measure cold"} })
    if r~=1 then return end

    -- Use best-Duv entry's CCT/Duv to compute correction
    local ref = hist.best_duv or hist.entries[1]
    if not ref or not ref.cct or not ref.duv then return end

    local correction = color_math.get_correction(goals.cct, goals.duv, ref.cct, ref.duv)
    -- calibrate_group is defined in Section 4 – call via pcall after it's defined
    -- (forward reference: we call it from main after all functions are defined)
    return correction.target_x, correction.target_y, ref.date
end

-- Collect Sekonic measurements. When hist is provided (first attempt),
-- prior best values are shown as context in each prompt.
-- When config contains bridge_ip the operator can trigger a remote measurement.
-- Returns: measured table (or nil on cancel), used_bridge (bool).
local function get_measurement_params(display, attempt, goals, hist, config, ctx, last_apply)
    local suffix     = attempt>1 and string.format(" (attempt %d)", attempt) or ""
    local leadin     = measurement_leadin(last_apply, attempt)
    local track_cri  = tracks_spectral_goal(goals.cri)
    local track_r9   = tracks_spectral_goal(goals.r9)
    local track_tlci = tracks_spectral_goal(goals.tlci)
    local meter_name = (goals.meter==METER_C700) and "C-700/C-800" or "C-7000"

    -- ── Remote bridge mode (C-7000 session meter only — D-91) ───────────────
    if config and config.bridge_ip and config.bridge_ip ~= ""
       and goals.meter == METER_C7000 then
        ::bridge_retry::
        local mode = MessageBox({
            title   = fixture_context_title(ctx, "Measurement" .. suffix),
            message = with_fixture_context(ctx, leadin .. string.format(
                "Bridge: %s:%d\n\n"
                .."How would you like to take this measurement?\n\n"
                .."  Remote   \xe2\x80\x93 trigger %s via bridge\n"
                .."            (console pauses ~2\xe2\x80\x935 s)\n\n"
                .."  Manual   \xe2\x80\x93 type values from meter display",
                config.bridge_ip, config.bridge_port or 8765, meter_name)),
            display_handle = display,
            buttons = {"Remote Measurement", "Enter Manually", "Cancel"},
        })
        if mode == nil or mode == 3 then return nil, false end

        if mode == 1 then
            local measured, err = bridge_fetch_measurement(config)
            if measured then
                local lines = {
                    string.format("  CCT  : %dK", measured.cct),
                    string.format("  Duv  : %+.4f", measured.duv),
                }
                if track_cri then
                    lines[#lines + 1] = string.format("  CRI  : %d", measured.cri or 0)
                end
                if track_r9 then
                    lines[#lines + 1] = string.format("  R9   : %d", measured.r9 or 0)
                end
                if track_tlci and measured.tlci then
                    lines[#lines + 1] = string.format("  TLCI : %d", measured.tlci)
                end
                local conf = MessageBox({
                    title   = fixture_context_title(ctx, "Measurement Received" .. suffix),
                    message = with_fixture_context(ctx, string.format(
                        "Values from %s meter:\n\n%s\n\nUse these values?",
                        meter_name, table.concat(lines, "\n"))),
                    display_handle = display,
                    buttons = {"Accept", "Re-measure", "Enter Manually"},
                })
                if conf == nil    then return nil, false end
                if conf == 1      then return measured, true end
                if conf == 2      then goto bridge_retry end
                -- conf == 3: fall through to manual entry
            else
                local err_r = MessageBox({
                    title   = fixture_context_title(ctx, "Bridge Error"),
                    message = with_fixture_context(ctx, string.format(
                        "Could not get a measurement from the bridge.\n\n"
                        .."Error: %s\n\n"
                        .."Check:\n"
                        .."  \xe2\x80\xa2 Bridge is running on %s\n"
                        .."  \xe2\x80\xa2 C-7000 is connected via USB\n"
                        .."  \xe2\x80\xa2 Bridge IP in config.json is correct",
                        tostring(err), config.bridge_ip)),
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
       and goals.meter == METER_C700 and attempt == 1 then
        -- D-92: bridge configured but C-700/C-800 session — manual only
    end
    -- ── Manual entry ──────────────────────────────────────────────────────────

    local function prior(rec, field, fmt)
        if attempt==1 and rec and rec[field]~=nil then
            return string.format("\n  Prior best: "..fmt.." (%s)", rec[field], rec.date or "?")
        end
        return ""
    end

    local cct = get_number_input(display, fixture_context_title(ctx, "Measured CCT"..suffix),
        with_fixture_context(ctx, leadin .. string.format("CCT reading from Sekonic %s.\nRange: %d – %d K%s",
            meter_name, CCT_MIN, CCT_MAX,
            prior(hist and hist.best_duv, "cct", "%dK"))),
        CCT_MIN, CCT_MAX)
    if not cct then return nil end

    local duv = get_number_input(display, fixture_context_title(ctx, "Measured Duv"..suffix),
        with_fixture_context(ctx, string.format("Duv (\xce\x94uv) from Sekonic %s.\nRange: %g to %+g\n\n"
            .."+value = green  |  -value = magenta%s",
            meter_name, DUV_MIN, DUV_MAX,
            prior(hist and hist.best_duv, "duv", "%+.4f"))),
        DUV_MIN, DUV_MAX)
    if not duv then return nil end

    -- Show GDTF-rated CRI as context if available (passed via goals.gdtf_cri)
    local gdtf_cri_hint = (attempt==1 and goals.gdtf_cri)
        and string.format("\n  Manufacturer rated: %d", goals.gdtf_cri) or ""

    local cri, r9, tlci = nil, nil, nil
    if track_cri then
        cri = get_number_input(display, fixture_context_title(ctx, "Measured CRI (Ra)"..suffix),
            with_fixture_context(ctx, string.format("CRI (Ra) from Sekonic %s.\nRange: %d – %d%s%s",
                meter_name, CRI_MIN, CRI_MAX,
                gdtf_cri_hint,
                prior(hist and hist.best_cri, "cri", "%d"))),
            CRI_MIN, CRI_MAX)
        if not cri then return nil end
    end

    if track_r9 then
        r9 = get_number_input(display, fixture_context_title(ctx, "Measured R9"..suffix),
            with_fixture_context(ctx, string.format("R9 (deep red) from Sekonic %s.\nRange: %d – %d\n\n"
                .."Critical for skin tones and costumes on camera.%s",
                meter_name, CRI_MIN, CRI_MAX,
                prior(hist and hist.best_r9, "r9", "%d"))),
            CRI_MIN, CRI_MAX)
        if not r9 then return nil end
    end

    if track_tlci then
        tlci = get_number_input(display, fixture_context_title(ctx, "Measured TLCI"..suffix),
            with_fixture_context(ctx, string.format("TLCI from Sekonic C-7000.\nRange: %d – %d\n\n"
                .."Television Lighting Consistency Index.\nBroadcast ready: 90+%s",
                CRI_MIN, CRI_MAX,
                prior(hist and hist.best_tlci, "tlci", "%d"))),
            CRI_MIN, CRI_MAX)
        if not tlci then return nil end
    end

    return { cct=cct, duv=duv, cri=cri, r9=r9, tlci=tlci }, false
end

local function goals_summary_line(goals)
    local parts = { string.format("%dK", goals.cct) }
    if goals.duv~=0 then parts[#parts+1]=string.format("Duv%+.3f", goals.duv) end
    local function ms(label, goal)
        if not goal or goal.mode==GOAL_SKIP then return nil end
        if goal.mode==GOAL_MAX then return label..":max" end
        return string.format("%s:\xe2\x89\xa5%d", label, goal.value)
    end
    local s = ms("CRI",goals.cri);  if s then parts[#parts+1]=s end
    local s2= ms("R9", goals.r9);   if s2 then parts[#parts+1]=s2 end
    local s3= ms("TLCI",goals.tlci);if s3 then parts[#parts+1]=s3 end
    local prefix = goals.mode==MODE_REFERENCE
        and string.format("Ref: %s  |  ", goals.ref_group) or ""
    return prefix.."Goals: "..table.concat(parts,"  ")
end

-- Show quality assessment and correction summary.
-- caps (optional): GDTF capability table.
-- Returns true = apply, false = skip.
local function show_assessment(display, group, goals, measured, correction, attempt, caps, ctx)
    local track_cri  = tracks_spectral_goal(goals.cri)
    local track_r9   = tracks_spectral_goal(goals.r9)
    local track_tlci = tracks_spectral_goal(goals.tlci)
    local duv_rating = color_math.rate_duv(measured.duv)

    local quality_lines = {}
    if track_cri and measured.cri then
        quality_lines[#quality_lines + 1] = string.format(
            "  CRI (Ra) :  %3d  \xe2\x86\x92  %-11s%s",
            measured.cri, color_math.rate_quality(measured.cri, QUALITY.CRI),
            goal_status_str(measured.cri, goals.cri))
    end
    if track_r9 and measured.r9 then
        quality_lines[#quality_lines + 1] = string.format(
            "  R9       :  %3d  \xe2\x86\x92  %-11s%s",
            measured.r9, color_math.rate_quality(measured.r9, QUALITY.R9),
            goal_status_str(measured.r9, goals.r9))
    end
    if track_tlci and measured.tlci then
        quality_lines[#quality_lines + 1] = string.format(
            "  TLCI     :  %3d  \xe2\x86\x92  %-11s%s",
            measured.tlci, color_math.rate_quality(measured.tlci, QUALITY.TLCI),
            goal_status_str(measured.tlci, goals.tlci))
    end
    quality_lines[#quality_lines + 1] = string.format(
        "  Duv      : %+.4f  \xe2\x86\x92  %-11s", measured.duv, duv_rating)
    local quality_block = "== Quality ==\n\n" .. table.concat(quality_lines, "\n") .. "\n"

    -- Warnings
    local warns = {}
    if track_cri and measured.cri and measured.cri < QUALITY.CRI.acceptable then
        warns[#warns+1]="  WARNING: CRI below broadcast minimum (80)" end
    if track_r9 and measured.r9 and measured.r9 < QUALITY.R9.acceptable then
        warns[#warns+1]="  WARNING: R9 below broadcast minimum (50)"
        warns[#warns+1]="           Reds may appear dull on camera" end
    if track_tlci and measured.tlci and measured.tlci < QUALITY.TLCI.acceptable then
        warns[#warns+1]="  WARNING: TLCI below broadcast minimum (50)" end
    if math.abs(measured.duv) > QUALITY.DUV.acceptable then
        warns[#warns+1]="  WARNING: Strong green/magenta cast (|Duv| > 0.010)" end
    local warns_str = #warns>0 and ("\n"..table.concat(warns,"\n").."\n") or ""

    -- Hints (manual fallbacks when auto channels unavailable) ----------------
    local hints = {}
    local auto_ch = caps and color_math.compute_channel_adjustments(correction, caps, {}) or nil
    local duv_off = math.abs(measured.duv) > QUALITY.DUV.good

    if duv_off then
        local extreme = math.abs(measured.duv) > 0.020
        if caps then
            if caps.has_tint then
                if auto_ch and auto_ch.tint_changed then
                    hints[#hints+1] = string.format(
                        "  Tint: auto → %.1f (correct Duv %+.4f)", auto_ch.tint, measured.duv)
                end
            elseif caps.has_color_wheel_filters and auto_ch and auto_ch.wheel_changed then
                hints[#hints+1] = string.format(
                        "  Color wheel: auto → \"%s\"", auto_ch.color_wheel_slot or "?")
            elseif caps.has_color_wheel_filters then
                local slot_dir = measured.duv>0 and "Minus Green" or "Plus Green"
                hints[#hints+1] = "  Color wheel: no matching slot found – try "..slot_dir
            else
                local gh = color_math.gel_hint(measured.duv)
                if gh then hints[#hints+1] = "  Gel (no Tint/wheel): "..gh end
            end
            if extreme and caps.has_tint then
                hints[#hints+1] = "  Physical gel may also be needed – Duv extreme"
            end
        else
            local gh = color_math.gel_hint(measured.duv)
            if gh then hints[#hints+1] = "  Physical gel: "..gh end
        end
    end

    if caps then
        local dk = correction.delta_cct
        if math.abs(dk)>200 then
            if dk>0 and caps.has_cto and auto_ch and auto_ch.cto_changed then
                hints[#hints+1] = string.format("  CTO: auto → %.1f (need warmer)", auto_ch.cto)
            elseif dk<0 and caps.has_ctb and auto_ch and auto_ch.ctb_changed then
                hints[#hints+1] = string.format("  CTB: auto → %.1f (need cooler)", auto_ch.ctb)
            elseif dk>0 and caps.has_cto then
                hints[#hints+1] = "  CTO: channel available – included in apply"
            elseif dk<0 and caps.has_ctb then
                hints[#hints+1] = "  CTB: channel available – included in apply"
            elseif caps.has_color_wheel and auto_ch and auto_ch.wheel_changed then
                hints[#hints+1] = string.format(
                    "  Color wheel: auto → \"%s\" for CCT", auto_ch.color_wheel_slot or "?")
            end
        end
    end

    -- Spectral limits (cannot be fixed via console) ──────────────────────────
    if track_cri and measured.cri and measured.cri < 85 then
        hints[#hints+1]="  CRI: Cannot be improved via console – try a different"
        hints[#hints+1]="       fixture or enable the fixture's high-CRI mode" end
    if track_r9 and measured.r9 and measured.r9 < 65 then
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

    local msg = with_fixture_context(ctx, string.format(
        "Attempt %d  |  %s\n\n"
     .."%s"
     .."%s\n"
     .."== Correction ==\n\n"
     .."  Measured :  %dK  Duv %+.4f\n"
     .."  Target   :  %dK  Duv %+.4f\n"
     .."  \xce\x94 Kelvin  :  %s\n"
     .."  \xce\x94 Duv     :  %s\n"
     .."%s\nApply correction to Group %s?",
        attempt, goals_summary_line(goals),
        quality_block,
        warns_str,
        measured.cct, measured.duv,
        goals.cct, goals.duv,
        dkcct_s, dkduv_s,
        hints_str, group))

    echo_lighttune_block(
        fixture_context_title(ctx, string.format("Assessment – %s (attempt %d)", group, attempt)),
        string.format(
            "Measured %dK Duv %+.4f  →  target %dK Duv %+.4f\n"
            .. "  Δ Kelvin %s   Δ Duv %s\n"
            .. "(Full details echoed to System Monitor)",
            measured.cct, measured.duv, goals.cct, goals.duv, dkcct_s, dkduv_s))

    local result = MessageBox({ title=fixture_context_title(ctx, string.format("Assessment – %s (attempt %d)", group, attempt)),
        message=msg, display_handle=display, buttons={"Apply","Skip"} })
    return result==1
end

local function show_result(display, success, ctx, method, err_msg)
    if success then
        MessageBox({ title=fixture_context_title(ctx, "Correction Applied"),
            message=with_fixture_context(ctx, string.format(
                "Correction applied.\nMethod: %s\n\nRe-measure with Sekonic meter to confirm.", method)),
            display_handle=display, buttons={"OK"} })
    else
        MessageBox({ title=fixture_context_title(ctx, "Apply Failed"),
            message=with_fixture_context(ctx, string.format(
                "Could not apply correction.\n\nError: %s", tostring(err_msg))),
            display_handle=display, buttons={"OK"} })
    end
end

local function ask_group_done(display, ctx, attempt)
    local label = fixture_label(ctx)
    local r = MessageBox({ title=fixture_context_title(ctx, string.format("%s – Done?", label)),
        message=with_fixture_context(ctx, string.format(
            "Attempt %d\n\nHappy with this fixture?\n\n"
            .."  Done          – mark complete and move on\n"
            .."  Measure Again – re-take a Sekonic reading", attempt)),
        display_handle=display, buttons={"Done","Measure Again"} })
    return r==1
end

-- v2: `goals` here is the session-wide goals_base (cct_list, not a single
-- cct) since a session can now batch several Kelvin targets. Each
-- session_log entry carries its own `kelvin` field (set in main() when the
-- entry is logged) so the per-group lines can say which target they were
-- calibrated against, while the header lists every target in the batch.
local function show_session_summary(display, session_log, goals)
    if #session_log==0 then return end
    local cct_strs = {}
    for _, k in ipairs(goals.cct_list or {}) do cct_strs[#cct_strs+1] = k.."K" end
    local header = table.concat(cct_strs, ", ")
    if goals.duv and goals.duv ~= 0 then header = header..string.format("  Duv%+.3f", goals.duv) end
    do
        local function ms(label, goal)
            if not goal or goal.mode==GOAL_SKIP then return nil end
            if goal.mode==GOAL_MAX then return label..":max" end
            return string.format("%s:â¥%d", label, goal.value)
        end
        local s = ms("CRI",goals.cri);  if s then header=header.."  "..s end
        local s2= ms("R9", goals.r9);   if s2 then header=header.."  "..s2 end
        local s3= ms("TLCI",goals.tlci);if s3 then header=header.."  "..s3 end
    end

    local lines = {
        string.format("== Session Summary  (%d group%s) ==\n", #session_log, #session_log==1 and "" or "s"),
        header.."\n",
    }
    for _, entry in ipairs(session_log) do
        local m   = entry.measured
        local cor = entry.correction
        local dk  = cor and cor.delta_cct or 0
        local dk_str = dk>0 and string.format("+%dK",dk) or dk<0 and string.format("%dK",dk) or "0K"

        local fails = {}
        local function chk(label, val, goal)
            if not goal or goal.mode == GOAL_SKIP then return end
            if goal.mode == GOAL_MIN and val < goal.value then
                fails[#fails + 1] = label
            end
        end
        local entry_goals = {
            cct  = entry.kelvin or goals.cct,
            duv  = goals.duv,
            cri  = goals.cri,
            r9   = goals.r9,
            tlci = goals.tlci,
        }
        if m then
            if not goals_met(m, entry_goals) then
                if math.abs(m.cct - entry_goals.cct) > CCT_GOAL_TOLERANCE then
                    fails[#fails + 1] = string.format("CCT %dK (target %dK)", m.cct, entry_goals.cct)
                end
                if math.abs(m.duv - entry_goals.duv) > QUALITY.DUV.acceptable then
                    fails[#fails + 1] = string.format("Duv %+.3f (target %+.3f)", m.duv, entry_goals.duv)
                end
            end
            chk("CRI", m.cri, goals.cri); chk("R9", m.r9, goals.r9)
            if m.tlci then chk("TLCI", m.tlci, goals.tlci) end
        end
        local spectral_tracked = goals.cri.mode ~= GOAL_SKIP
            or goals.r9.mode ~= GOAL_SKIP
            or goals.tlci.mode ~= GOAL_SKIP
        local status
        if m and goals_met(m, entry_goals) then
            status = spectral_tracked and "OK — all goals met" or "OK — CCT/Duv met"
        elseif #fails > 0 then
            status = "Below goal: " .. table.concat(fails, ", ")
        elseif not spectral_tracked then
            status = "CCT/Duv not met"
        else
            status = "Below goal"
        end

        local metrics=""
        if m then
            local parts = { string.format("CCT:%dK", m.cct), string.format("Duv:%+.3f", m.duv) }
            if tracks_spectral_goal(goals.cri) and m.cri then
                parts[#parts + 1] = string.format("CRI:%d", m.cri)
            end
            if tracks_spectral_goal(goals.r9) and m.r9 then
                parts[#parts + 1] = string.format("R9:%d", m.r9)
            end
            if tracks_spectral_goal(goals.tlci) and m.tlci then
                parts[#parts + 1] = string.format("TLCI:%d", m.tlci)
            end
            metrics = table.concat(parts, "  ")
        end
        local fix_str=""
        if entry.make and entry.model then fix_str=string.format(" [%s %s]",entry.make,entry.model) end
        local kelvin_str = entry.kelvin and string.format(" @ %dK", entry.kelvin) or ""
        local attempt_str
        if entry.attempt_group or entry.attempt_individual then
            attempt_str = string.format(
                "%d total (%d group + %d solo)",
                entry.attempt or 0,
                entry.attempt_group or 0,
                entry.attempt_individual or 0)
        else
            attempt_str = tostring(entry.attempt or 0)
        end

        lines[#lines+1]=string.format(
            "\nGroup: %s%s%s\n  %s  \xce\x94K:%s  (%s attempt%s)\n  Status: %s",
            entry.group, kelvin_str, fix_str, metrics, dk_str, attempt_str,
            entry.attempt==1 and "" or "s", status)
    end
    MessageBox({ title="Session Complete", message=table.concat(lines,"\n"),
        display_handle=display, buttons={"OK"} })
end

local function show_crash_log(display)
    local text = crash_log.format_for_display(15)
    local path = crash_log.path() or "data/crash_log.jsonl"
    MessageBox({
        title = "Crash Log",
        message = string.format(
            "Recent plugin events (newest last):\n\n%s\n\n"
            .. "Full log file:\n%s",
            text, path),
        display_handle = display,
        buttons = {"OK"},
    })
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
    coroutine.yield(0)
    local result = bridge_client.fetch_measurement(config)
    coroutine.yield(0)
    if result.ok then return result.data end
    return nil, format_bridge_error(result, config)
end

bridge_check_status = function(config)
    if not config or not config.bridge_ip or config.bridge_ip == "" then
        return false, false, nil, false, false, false, false, nil, "no_bridge_configured"
    end
    local result = bridge_client.check_status(config)
    if not result.ok then
        local reason = tostring(result.kind or "?") .. ": " .. tostring(result.message or "?")
        return false, false, nil, false, false, false, false, nil, reason
    end
    local d = result.data
    return true, d.connected, d.meter, d.device_configured, d.protocol_captured,
           d.trigger_discovered, d.auth_required, d.last_error, nil
end

local function bridge_meter_to_plugin(meter_name)
    if meter_name == "C-7000" then return METER_C7000 end
    if meter_name == "C-700" or meter_name == "C-800" then return METER_C700 end
    return nil
end

-- When bridge_ip is configured, read the meter model from /status so the
-- operator is not asked to pick C-700 vs C-7000 at session start.
local function resolve_meter_from_bridge(config)
    if not config or not config.bridge_ip or config.bridge_ip == "" then
        return nil, nil
    end
    local ok, connected, meter_name = bridge_check_status(config)
    if not ok or not connected or not meter_name then
        return nil, meter_name
    end
    return bridge_meter_to_plugin(meter_name), meter_name
end

-- Build a bridge web UI URL (dashboard or fixtures page).
local function bridge_web_url(config, page)
    if not config or not config.bridge_ip or config.bridge_ip == "" then
        return nil
    end
    local path = (page == "fixtures") and "/fixtures" or "/dashboard"
    local url = string.format("http://%s:%d%s",
        config.bridge_ip, config.bridge_port or 8765, path)
    if config.bridge_api_key and config.bridge_api_key ~= "" then
        url = url .. "?key=" .. config.bridge_api_key
    end
    return url
end

-- Best-effort: open URL in the system browser. Works on onPC (Mac/Windows/Linux)
-- when os.execute is available; hardware consoles typically block shell access.
local function open_url_in_browser(url)
    if not url or url == "" then return false end
    local opened = false
    pcall(function()
        if not os.execute then return end
        local host = "Linux"
        pcall(function() host = HostOS() end)
        if host == "Windows" then
            opened = os.execute(string.format('start "" "%s"', url))
        elseif host == "Mac" then
            opened = os.execute(string.format('open "%s"', url))
        else
            opened = os.execute(string.format('xdg-open "%s"', url))
        end
    end)
    return opened and true or false
end

local function open_bridge_browser(config, page)
    local url = bridge_web_url(config, page)
    if not url then return false, nil end
    if open_url_in_browser(url) then
        return true, url
    end
    Echo("Lighttune bridge UI: " .. url)
    return false, url
end

-- Open bridge web UI; show URL dialog when the console cannot launch a browser.
local function prompt_open_bridge(display, config, page)
    if not bridge_configured(config) then
        MessageBox({ title = "Open Bridge",
            message = "No bridge configured.\n\n"
                  .. "Add bridge_ip and bridge_port to config.json\n"
                  .. "to enable the bridge web dashboard.\n\n"
                  .. 'Example:  "bridge_ip": "127.0.0.1"',
            display_handle = display, buttons = {"OK"} })
        return
    end
    push_fixture_log_to_bridge(config, true)
    local opened, url = open_bridge_browser(config, page or "dashboard")
    if not opened then
        local page_label = (page == "fixtures") and "fixture log" or "bridge dashboard"
        MessageBox({ title = "Open Bridge",
            message = string.format(
                "Could not open a browser from this console.\n\n"
                .. "Open the %s on a phone, tablet, or laptop\n"
                .. "on the same network:\n\n  %s",
                page_label, url or "?"),
            display_handle = display, buttons = {"OK"} })
    end
end

-- v2: replaces the old "Bridge Status" menu button -- a full bridge check
-- now happens automatically once, right after the operator picks C-7000 +
-- has a bridge configured, instead of requiring a separate manual menu
-- visit before every session. Returns:
--   ready  (bool)   -- true only when reachable AND meter connected AND
--                       protocol captured AND trigger discovered (fully
--                       hands-free); false for anything short of that
--   note   (string) -- one-line status to fold into the session-start
--                       message, or nil when there's nothing worth saying
-- Never blocks calibration: on any failure this just returns ready=false
-- and a note, so the caller falls back to manual measurement -- exactly
-- the situation when the meter is unplugged/off between sessions.
preflight_bridge_check = function(display, config, meter)
    if meter ~= METER_C7000 then
        return false, nil  -- bridge is C-7000-only; C-700/C-800 always manual
    end
    if not config or not config.bridge_ip or config.bridge_ip == "" then
        return false, nil  -- no bridge configured: silent, manual is the only mode anyway
    end

    local ok, connected, meter_name, device_configured, protocol_captured,
          trigger_discovered, auth_required, last_error, reason = bridge_check_status(config)

    if not ok then
        return false, string.format("Bridge unreachable (%s) — using manual entry.", tostring(reason))
    end
    if not connected then
        return false, "Bridge reachable, but no meter connected — using manual entry."
    end
    if not (device_configured and protocol_captured) then
        return false, "Bridge connected but not fully set up yet — using manual entry."
    end
    if not trigger_discovered then
        return false, "Bridge ready, but remote trigger not yet discovered — using manual entry."
    end

    return true, string.format("Bridge ready — %s connected, hands-free remote measurement enabled.",
        meter_name or "meter")
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
          auth_required, last_error, fail_reason = bridge_check_status(config)

    if not reachable then
        MessageBox({
            title   = "Bridge Unreachable",
            message = string.format(
                "Cannot connect to bridge at %s:%d\n\n"
                .."Reason: %s\n\n"
                .."Check:\n"
                .."  \xe2\x80\xa2 Bridge Pi is powered and on the network\n"
                .."  \xe2\x80\xa2 IP in config.json is correct\n"
                .."  \xe2\x80\xa2 Bridge service is running\n\n"
                .."From the Pi terminal: curl http://%s:%d/status",
                config.bridge_ip, config.bridge_port or 8765,
                tostring(fail_reason or "unknown"),
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

-- Note: has_color_wheel_filters (specific slot names like "1/4 CTO") are read
-- from GDTF ChannelFunction names when a ColorWheel attribute is present.
--------------------------------------------------------------------------------

local function has_correctable_color(caps)
    return gdtf_caps.has_correctable_color(caps)
end

local function has_native_color_channels(caps)
    return gdtf_caps.has_native_color_channels(caps)
end

local function read_caps_from_fixture_type(ft, fixture)
    return gdtf_caps.read_from_fixture_type(ft, fixture)
end

-- Read fixture colour capabilities from GDTF via the MA3 Patch API.
local function read_capabilities_from_patch(group_name)
    if not group_name then return gdtf_caps.finalize_caps(nil, false) end

    local caps, found = nil, false
    pcall(function()
        local grp = find_group(group_name)
        if not grp then return end
        local sel = grp.SelectionData or grp.selectiondata
        if sel then
            for _, entry in ipairs(sel) do
                local sf = entry.sf_index or entry.SFIndex or entry.SfIndex
                if sf and GetSubfixture then
                    local sub = GetSubfixture(sf)
                    if sub then
                        local fix = sub.fixture or sub.Fixture
                        if fix then
                            local ft = fix.FixtureType or fix.fixturetype
                            if ft then
                                caps = gdtf_caps.read_from_fixture_type(ft, fix)
                                found = caps and caps.gdtf_source
                                if found then return end
                            end
                        end
                    end
                end
            end
        end
    end)

    if not found then
        pcall(function()
            local grp = find_group(group_name)
            if not grp then return end
            local members = grp.Members
            if not members or members:Count() == 0 then return end
            local fixture = members:Child(0)
            if not fixture then return end
            local ft = fixture.FixtureType or fixture.fixturetype
            if ft then
                caps = gdtf_caps.read_from_fixture_type(ft, fixture)
                found = caps and caps.gdtf_source
            end
        end)
    end

    if caps then return caps end
    return gdtf_caps.finalize_caps(nil, false)
end

-- Per-fixture capabilities (Phase 2 solo pass) — same fixture's patched DMX mode.
local function read_capabilities_from_fixture(fnum)
    if not fnum then return gdtf_caps.finalize_caps(nil, false) end

    local caps, found = nil, false
    pcall(function()
        local ft, fix = nil, nil
        if GetSubfixture then
            local sub = GetSubfixture(fnum)
            if sub then
                fix = sub.fixture or sub.Fixture
                if fix then ft = fix.FixtureType or fix.fixturetype end
            end
        end
        if not ft and ObjectList then
            local objs = ObjectList("Fixture " .. tostring(fnum))
            if objs and objs[1] then
                fix = objs[1]
                ft = objs[1].fixturetype or objs[1].FixtureType
            end
        end
        if ft then
            caps = gdtf_caps.read_from_fixture_type(ft, fix)
            found = caps and caps.gdtf_source
        end
    end)

    if caps then return caps end
    return gdtf_caps.finalize_caps(nil, false)
end

--------------------------------------------------------------------------------
-- SECTION 4: FIXTURE APPLICATION
--------------------------------------------------------------------------------

-- Without an At-filter, SetColor and Store Preset activate every attribute on
-- the selection (pan, tilt, shutter, …). The factory "Only Color" filter limits
-- programmer activity to color attributes only — what this plugin actually touches.
--
-- Position (pan/tilt/XYZ) is NEVER written except via apply_focus_position()
-- when the operator supplies a focus preset (config or session prompt).
local COLOR_FILTER_CMDS = {
    'Filter "Only Color"',
    "Filter 5",  -- factory pool fallback: All(1), Prog Only(2), Dimmer(3), Position(4), Color(5)
}
local DIMMER_FILTER_CMDS = {
    'Filter "Only Dimmer"',
    "Filter 3",  -- factory pool fallback: All(1), Prog Only(2), Dimmer(3), Position(4), Color(5)
}
local DEFAULT_AT_FILTER_CMD = "Filter 1"  -- "All" — restore after each operation

-- Position preset (operator-prepared, fixtures aimed at Sekonic) — position attrs only.
local POSITION_FILTER_CMDS = {
    'Filter "Only Position"',
    "Filter 4",  -- factory pool fallback: All(1), Prog Only(2), Dimmer(3), Position(4), Color(5)
}

local POSITION_ATTRS = {
    Pan = true, Tilt = true, PanTilt = true,
    XYZ_X = true, XYZ_Y = true, XYZ_Z = true,
    X = true, Y = true, Z = true,
    Rot_X = true, Rot_Y = true, Rot_Z = true,
}

local function is_position_attribute(attr)
    if not attr or attr == "" then return false end
    if POSITION_ATTRS[attr] then return true end
    local lower = tostring(attr):lower()
    if lower:find("^pan") or lower:find("^tilt") or lower:find("^xyz") then return true end
    if lower:find("position") then return true end
    return false
end

-- SetColor only activates the primary color coords (CIE xy / HSB). Before apply
-- and preset store, knock in every color attribute on the selection so RGB,
-- CTO/CTB, Tint, color wheel, etc. are all in the programmer and get saved.
local ENABLE_COLOR_ATTR_CMDS = {
    'On FeatureGroup "Color"',
    "On FeatureGroup 2",  -- factory default: Dimmer=1, Color=2
}

local function call_color_only_filter()
    for _, cmd in ipairs(COLOR_FILTER_CMDS) do
        local ok = pcall(function() Cmd(cmd) end)
        if ok then return true end
    end
    return false
end

local function call_dimmer_only_filter()
    for _, cmd in ipairs(DIMMER_FILTER_CMDS) do
        if pcall(function() Cmd(cmd) end) then return true end
    end
    return false
end

local function restore_default_at_filter()
    pcall(function() Cmd(DEFAULT_AT_FILTER_CMD) end)
end

local function call_position_only_filter()
    for _, cmd in ipairs(POSITION_FILTER_CMDS) do
        if pcall(function() Cmd(cmd) end) then return true end
    end
    return false
end

local function normalize_focus_preset_id(raw)
    if not raw or raw == "" then return nil end
    raw = tostring(raw):match("^%s*(.-)%s*$")
    if raw == "" then return nil end
    if raw:find("%.") then return raw end
    return "2." .. raw  -- bare number → position pool (Preset 2.x)
end

-- ONLY code path that writes pan/tilt/XYZ — requires operator focus preset.
local function apply_focus_position(preset_id)
    if not preset_id or preset_id == "" then return true end
    call_position_only_filter()
    local ok = pcall(function() Cmd("At Preset " .. preset_id) end)
    restore_default_at_filter()
    if ok then
        crash_log.trace("info", "focus_preset_applied", { preset = tostring(preset_id) })
    else
        crash_log.trace("warn", "focus_preset_failed", { preset = tostring(preset_id) })
    end
    return ok
end

local function enable_all_color_attributes()
    for _, cmd in ipairs(ENABLE_COLOR_ATTR_CMDS) do
        if pcall(function() Cmd(cmd) end) then return true end
    end
    return false
end

-- MA3 group syntax: `Group 1` selects pool index 1; `Group "Front Wash"` selects
-- by name. Quoting a bare number (`Group "1"`) looks up a *named* group "1" and
-- throws "illegal object" when no such name exists — try numeric index first.
local function group_select_commands(group)
    local ref = tostring(group):match("^%s*(.-)%s*$")
    local cmds, seen = {}, {}
    local function add(cmd)
        if cmd and not seen[cmd] then seen[cmd] = true; cmds[#cmds + 1] = cmd end
    end

    local num = tonumber(ref)
    if num then
        add("Group " .. num)
    else
        add('Group "' .. ref:gsub('"', '\\"') .. '"')
        pcall(function()
            local dp = DataPool(); if not dp then return end
            local groups = dp.Groups or dp.groups; if not groups then return end
            local target = find_group(ref)
            if not target then return end
            local count = 0
            pcall(function() count = groups:Count() end)
            for i = 0, math.max(count - 1, 0) do
                if groups:Child(i) == target then add("Group " .. (i + 1)); break end
            end
        end)
    end
    return cmds
end

local function select_group(group)
    local last_err
    for _, cmd in ipairs(group_select_commands(group)) do
        local ok, err = pcall(function() Cmd(cmd) end)
        if ok then return true, nil end
        last_err = err
        crash_log.trace("warn", "cmd_failed", { cmd = cmd, err = tostring(err), group = tostring(group) })
    end
    return false, tostring(last_err or "group not found")
end

local function apply_color_xyY(x,y)
    call_color_only_filter()
    enable_all_color_attributes()
    local ok,err=pcall(function() SetColor("xyY",x,y,1.0,1.0,1.0,false) end)
    restore_default_at_filter()
    if not ok then return false,tostring(err) end
    return true,nil
end

local function apply_color_hsb(x,y)
    local r,g,b=color_math.xy_to_rgb(x,y); local h,s,_=color_math.rgb_to_hsb(r,g,b)
    call_color_only_filter()
    enable_all_color_attributes()
    local ok,err=pcall(function() SetColor("HSB",h,s,1.0,1.0,1.0,false) end)
    restore_default_at_filter()
    if not ok then return false,tostring(err) end
    return true,nil
end

-- Apply Tint / CTO / CTB / CTC / ColorWheel (when available) plus SetColor xy/HSB.
local function apply_calibration_correction(correction, caps, prev_channels)
    local ch = color_math.compute_channel_adjustments(correction, caps, prev_channels)
    call_color_only_filter()
    enable_all_color_attributes()

    local methods = {}
    local errors  = {}
    local native_applied = false

    local function try_attr(attr, val)
        if not attr then return false end
        if is_position_attribute(attr) then
            crash_log.trace("warn", "position_attr_blocked", { attr = attr })
            return false
        end
        local cmd
        if type(val) == "string" then
            cmd = string.format('Attribute "%s" At "%s"', attr, val:gsub('"', '\\"'))
        else
            cmd = string.format('Attribute "%s" At %.4f', attr, val)
        end
        local ok, err = pcall(function() Cmd(cmd) end)
        if ok then
            methods[#methods + 1] = attr
            native_applied = true
        else
            errors[#errors + 1] = attr .. ": " .. tostring(err)
            crash_log.trace("warn", "attr_apply_failed", { attr = attr, err = tostring(err) })
        end
        return ok
    end

    if caps then
        if caps.has_ctc and ch.ctc_changed and ch.ctc_kelvin then
            try_attr(caps.ctc_attr or "CTC", ch.ctc_kelvin)
        end
        if caps.has_tint and ch.tint_changed then
            try_attr(caps.tint_attr or "Tint", ch.tint)
        end
        if caps.has_cto and ch.cto_changed then
            try_attr(caps.cto_attr or "CTO", ch.cto)
        end
        if caps.has_ctb and ch.ctb_changed then
            try_attr(caps.ctb_attr or "CTB", ch.ctb)
        end
        if caps.color_wheel_attr and ch.wheel_changed and ch.color_wheel_slot then
            try_attr(caps.color_wheel_attr, ch.color_wheel_slot)
        end
    end

    local use_setcolor = not has_native_color_channels(caps) or not native_applied
    if use_setcolor then
        local xy_ok, xy_err = pcall(function()
            SetColor("xyY", correction.target_x, correction.target_y, 1.0, 1.0, 1.0, false)
        end)
        if xy_ok then
            methods[#methods + 1] = "xyY"
        else
            local r, g, b = color_math.xy_to_rgb(correction.target_x, correction.target_y)
            local h, s, _  = color_math.rgb_to_hsb(r, g, b)
            local hsb_ok, hsb_err = pcall(function()
                SetColor("HSB", h, s, 1.0, 1.0, 1.0, false)
            end)
            if hsb_ok then
                methods[#methods + 1] = "HSB"
            else
                errors[#errors + 1] = "SetColor: " .. tostring(hsb_err or xy_err)
            end
        end
    end

    restore_default_at_filter()

    return {
        success   = #methods > 0,
        method    = table.concat(methods, " + "),
        error_msg = #errors > 0 and table.concat(errors, " | ") or nil,
        channels  = ch,
    }
end

local function select_fixture(fixture_num)
    local cmd = "Fixture " .. tostring(fixture_num)
    local ok, err = pcall(function() Cmd(cmd) end)
    if not ok then
        crash_log.trace("warn", "cmd_failed", {
            cmd = cmd, err = tostring(err), fixture = tostring(fixture_num) })
        return false, tostring(err)
    end
    return true, nil
end

local function apply_calibration_to_group(group, correction, caps, prev_channels)
    local sel_ok, sel_err = select_group(group)
    if not sel_ok then return { success = false, method = "none", error_msg = sel_err } end
    return apply_calibration_correction(correction, caps, prev_channels)
end

local function apply_calibration_to_fixture(fixture_num, correction, caps, prev_channels)
    local sel_ok, sel_err = select_fixture(fixture_num)
    if not sel_ok then return { success = false, method = "none", error_msg = sel_err } end
    return apply_calibration_correction(correction, caps, prev_channels)
end

local function calibrate_group(group,x,y)
    local sel_ok,sel_err=select_group(group)
    if not sel_ok then return {success=false,method="none",error_msg=sel_err} end
    local xy_ok,xy_err=apply_color_xyY(x,y)
    if xy_ok then return {success=true,method="xyY (precision)",error_msg=nil} end
    local hsb_ok,hsb_err=apply_color_hsb(x,y)
    if hsb_ok then return {success=true,method="HSB (approx)",error_msg=nil} end
    return {success=false,method="none",
        error_msg=string.format("xyY: %s | HSB: %s",xy_err,hsb_err)}
end

-- Apply color to whatever is CURRENTLY selected (no group re-selection) --
-- used by the per-fixture loop below, where the current selection is a
-- single fixture within the group, not the whole group.
local function calibrate_current_selection(x,y)
    local xy_ok,xy_err=apply_color_xyY(x,y)
    if xy_ok then return {success=true,method="xyY (precision)",error_msg=nil} end
    local hsb_ok,hsb_err=apply_color_hsb(x,y)
    if hsb_ok then return {success=true,method="HSB (approx)",error_msg=nil} end
    return {success=false,method="none",
        error_msg=string.format("xyY: %s | HSB: %s",xy_err,hsb_err)}
end

--------------------------------------------------------------------------------
-- v2: PER-FIXTURE SOLO CALIBRATION (phase 2)
--
-- Different physical units of the same fixture model drift differently
-- (LED bin, dimmer-curve wear, gel/diffusion absorption), so a group-only
-- pass hides unit-to-unit variance. Phase 1 calibrates the whole group as
-- one block; phase 2 isolates each fixture with Solo and corrects individually.
--
-- Fixture numbers are read directly from the console's own selection-
-- walking API (SelectionFirst/SelectionNext) right after the group is
-- selected -- NOT assumed to be sequential (a group's fixtures can have any
-- patch numbers) and NOT driven by repeatedly pressing the "Next" keyword
-- (which steps an internal cursor whose behaviour this plugin can't verify
-- attempt-to-attempt). Reading the real numbers up front means every
-- subsequent "Fixture <n>" / "Solo On Fixture <n>" command below addresses
-- an exact, already-confirmed patch number -- there's no ambiguity about
-- which physical fixture is being measured.
--------------------------------------------------------------------------------

local function fixture_id_from_subfixture(sf_index)
    if sf_index == nil then return nil end
    local fid = sf_index
    pcall(function()
        if not GetSubfixture then return end
        local sub = GetSubfixture(sf_index)
        if not sub then return end
        fid = sub.FID or sub.fid or fid
        local fix = sub.fixture or sub.Fixture
        if fix then fid = fix.FID or fix.Fid or fix.fid or fid end
    end)
    return fid
end

local function append_unique_fixture_id(nums, seen, fid)
    if fid == nil or seen[fid] then return end
    seen[fid] = true
    nums[#nums + 1] = fid
end

-- Returns patched fixture IDs for every member of `group`.
-- Tries SelectionData → Members → SelectionFirst/Next (with GM3 true flag).
local MAX_GROUP_FIXTURES = 512

local function get_group_fixture_numbers(group)
    local nums, seen = {}, {}

    pcall(function()
        local grp = find_group(group)
        if not grp then return end
        local sel = grp.SelectionData or grp.selectiondata
        if not sel then return end
        for i, entry in ipairs(sel) do
            if i > MAX_GROUP_FIXTURES then break end
            local sf = entry.sf_index or entry.SFIndex or entry.SfIndex
            if sf then append_unique_fixture_id(nums, seen, fixture_id_from_subfixture(sf)) end
        end
    end)
    if #nums > 0 then return nums end

    pcall(function()
        local grp = find_group(group)
        if not grp then return end
        local members = grp.Members
        if not members then return end
        local count = 0
        pcall(function() count = members:Count() end)
        for i = 0, math.min(math.max(count - 1, 0), MAX_GROUP_FIXTURES - 1) do
            local m = members:Child(i)
            if not m then break end
            local sf = m.SubfixtureIndex or m.subfixtureindex or m.SFIndex or m.sf_index
            if sf then
                append_unique_fixture_id(nums, seen, fixture_id_from_subfixture(sf))
            else
                append_unique_fixture_id(nums, seen, m.FID or m.fid)
            end
        end
    end)
    if #nums > 0 then return nums end

    select_group(group)
    pcall(function()
        if not SelectionFirst then return end
        local function walk_selection(first_fn, next_fn)
            local idx = first_fn()
            local steps, visited = 0, {}
            while idx and steps < MAX_GROUP_FIXTURES do
                local key = tostring(idx)
                if visited[key] then break end
                visited[key] = true
                append_unique_fixture_id(nums, seen, fixture_id_from_subfixture(idx))
                local next_idx = next_fn(idx)
                if next_idx == idx then break end
                idx = next_idx
                steps = steps + 1
            end
        end
        walk_selection(
            function() return SelectionFirst(true) end,
            function(idx) return SelectionNext and SelectionNext(idx, true) end)
        if #nums == 0 then
            walk_selection(
                function() return SelectionFirst() end,
                function(idx) return SelectionNext and SelectionNext(idx) end)
        end
    end)
    return nums
end

local function solo_fixture_on(fixture_num)
    local ok,err=pcall(function() Cmd("Solo On Fixture "..tostring(fixture_num)) end)
    if not ok then return false,tostring(err) end
    return true,nil
end

local function solo_fixture_off(fixture_num)
    local ok,err=pcall(function() Cmd("Solo Off Fixture "..tostring(fixture_num)) end)
    if not ok then return false,tostring(err) end
    return true,nil
end

local function set_selection_dimmer_full()
    call_dimmer_only_filter()
    if pcall(function() Cmd('Attribute "Dimmer" At 100') end) then
        restore_default_at_filter()
        return true
    end
    restore_default_at_filter()
    return false
end

local function solo_selection_off(fnum)
    if fnum then
        solo_fixture_off(fnum)
    else
        pcall(function() Cmd("Solo Off") end)
    end
end

-- Select target, solo it, optionally aim via focus preset, dimmer 100%, color attrs on.
local function prepare_for_calibration(fnum, group, focus_preset)
    if fnum then
        select_fixture(fnum)
        solo_fixture_on(fnum)
    else
        select_group(group)
        pcall(function() Cmd("Solo On") end)
    end
    apply_focus_position(focus_preset)
    set_selection_dimmer_full()
    call_color_only_filter()
    enable_all_color_attributes()
    restore_default_at_filter()
end

-- Select + apply color to exactly one fixture by its real patch number.
local function calibrate_fixture(fixture_num, x, y)
    local sel_ok, sel_err = select_fixture(fixture_num)
    if not sel_ok then return {success=false,method="none",error_msg=sel_err} end
    return calibrate_current_selection(x, y)
end

-- Find the first empty slot at or after `start_index` in a Color preset
-- pool (DataPool().PresetPools[4] -- type 4 confirmed live). Empty = nil
-- entry, not index 0 (index 0 is not a valid preset number).
local function find_next_empty_preset_slot(pool_type, start_index)
    local idx = start_index or 1
    local ok, result = pcall(function()
        local dp = DataPool()
        if not dp then return nil end
        local pool = dp.PresetPools and dp.PresetPools[pool_type]
        if not pool then return nil end
        local i = idx
        local limit = idx + 9999
        while pool[i] ~= nil and i < limit do i = i + 1 end
        return i
    end)
    if not ok or not result then return idx end
    return result
end

-- Store the CURRENT selection's color into a new Color preset slot.
local function store_new_color_preset(name)
    local idx = find_next_empty_preset_slot(4, 1)
    call_color_only_filter()
    enable_all_color_attributes()
    local ok, err = pcall(function()
        Cmd(string.format('Store Preset 4.%d "%s" /AllForSelected /nc', idx, name))
    end)
    restore_default_at_filter()
    return ok, idx, err
end

-- Merge the CURRENT selection's color into an existing Color preset.
local function merge_color_preset(idx)
    call_color_only_filter()
    enable_all_color_attributes()
    local ok, err = pcall(function()
        Cmd(string.format('Store Preset 4.%d /merge /AllForSelected /nc', idx))
    end)
    restore_default_at_filter()
    return ok, err
end

-- Find the first empty slot in the Groups pool (same pattern as Color presets).
local function find_next_empty_group_slot(start_index)
    local idx = start_index or 1
    local ok, result = pcall(function()
        local dp = DataPool()
        if not dp then return nil end
        local groups = dp.Groups
        if not groups then return nil end
        local i = idx
        while groups[i] ~= nil do i = i + 1 end
        return i
    end)
    if not ok or not result then return idx end
    return result
end

local function store_new_group(name)
    local idx = find_next_empty_group_slot(1)
    local ok, err = pcall(function()
        Cmd(string.format('Store Group %d "%s" /nc', idx, name))
    end)
    return ok, idx, err
end

local function merge_group(idx)
    local ok, err = pcall(function()
        Cmd(string.format('Store Group %d /merge /nc', idx))
    end)
    return ok, err
end

-- tracker: { created, idx, name } — reuses existing group by name, then merges fixtures in.
local function save_fixture_to_tracker_group(display, tracker, name, fnum)
    if not fnum then return false, nil end
    select_fixture(fnum)

    if not tracker.idx then
        local existing = group_pool_index(name)
        if existing then
            tracker.idx = existing
            tracker.name = name
            tracker.created = true
        end
    end

    if not tracker.created then
        local ok, idx, err = store_new_group(name)
        if not ok then
            MessageBox({ title = "Group Save Failed",
                message = string.format("Could not store group '%s':\n\n%s", name, tostring(err)),
                display_handle = display, buttons = {"OK"} })
            return false, nil
        end
        tracker.idx = idx
        tracker.name = name
        tracker.created = true
        return true, idx
    end

    local ok, err = merge_group(tracker.idx)
    if not ok then
        MessageBox({ title = "Group Merge Failed",
            message = string.format("Could not merge into Group %d:\n\n%s",
                tracker.idx, tostring(err)),
            display_handle = display, buttons = {"OK"} })
        return false, tracker.idx
    end
    return true, tracker.idx
end

-- Incremental safety save: reuses Preset 4."5000K" (etc.) when it already exists.
-- kelvin_preset: { created, idx, name, kelvin }
local function save_fixture_to_kelvin_preset(display, kelvin_preset, kelvin, fnum, group)
    if fnum then
        select_fixture(fnum)
    elseif group then
        select_group(group)
    end

    local name = string.format("%dK", kelvin)
    if not kelvin_preset.idx then
        local existing = find_color_preset_by_name(name)
        if existing then
            kelvin_preset.idx = existing
            kelvin_preset.name = name
            kelvin_preset.created = true
        end
    end

    if not kelvin_preset.created then
        local ok, idx, err = store_new_color_preset(name)
        if not ok then
            MessageBox({ title = "Preset Save Failed",
                message = string.format("Could not store preset '%s':\n\n%s", name, tostring(err)),
                display_handle = display, buttons = {"OK"} })
            return false, nil
        end
        kelvin_preset.idx = idx
        kelvin_preset.name = name
        kelvin_preset.kelvin = kelvin
        kelvin_preset.created = true
        return true, idx
    end

    local ok, err = merge_color_preset(kelvin_preset.idx)
    if not ok then
        MessageBox({ title = "Preset Merge Failed",
            message = string.format("Could not merge into Preset 4.%d:\n\n%s",
                kelvin_preset.idx, tostring(err)),
            display_handle = display, buttons = {"OK"} })
        return false, kelvin_preset.idx
    end
    return true, kelvin_preset.idx
end

-- Popup before saving: fixture identity + measurements + what will be stored.
local function show_fixture_save_popup(display, ctx, measured, goals, attempt, passed, reason, bridge_active, config, measure_only)
    local fix_id = ctx.fnum and string.format("Fixture #%d", ctx.fnum) or "Whole group"
    local name_part = ctx.name and ("  " .. ctx.name) or ""
    local outcome = passed and "PASSED — goals met" or ("FAILED — " .. (reason or "did not reach goals"))
    local dest_group = passed and "CAL" or "UNCAL"
    local kelvin_name = goals.cct and string.format("%dK", goals.cct) or "Lighttune"

    local title = fixture_context_title(ctx, (passed and "Calibrated" or "Uncalibrated") .. " – " .. fix_id)
    local save_lines
    if measure_only then
        save_lines = string.format(
            "No color attributes — measure only.\n\n"
            .. "  • Add fixture to Group \"%s\"",
            dest_group)
    else
        save_lines = string.format(
            "  • Merge color into Preset \"%s\"\n"
            .. "  • Add fixture to Group \"%s\"",
            kelvin_name, dest_group)
    end

    local message = with_fixture_context(ctx, string.format(
        "%s%s\nAttempt %d\n\n"
        .. "Measurements:\n  %s\n\n"
        .. "Outcome: %s\n\n"
        .. "Saving:\n%s",
        fix_id, name_part, attempt,
        measured_metrics_summary(measured, goals),
        outcome, save_lines))

    ok_or_auto_continue(display, title, message, bridge_active, config)
end

-- After operator confirms: color preset + CAL or UNCAL fixture group.
local function finalize_fixture_save(display, ctx, measured, goals, fnum, group, attempt,
    passed, reason, kelvin_preset, cal_group, uncal_group, preset_snapshot, bridge_active, config,
    measure_only)
    show_fixture_save_popup(display, ctx, measured, goals, attempt, passed, reason,
        bridge_active, config, measure_only)

    if not measure_only then
        local preset_ok = save_fixture_to_kelvin_preset(
            display, kelvin_preset, goals.cct, fnum, group)
        if preset_ok then preset_snapshot.saved = true end
    end

    local tracker = passed and cal_group or uncal_group
    local group_name = passed and "CAL" or "UNCAL"
    save_fixture_to_tracker_group(display, tracker, group_name, fnum)
end

-- Legacy whole-selection store (cancel fallback when no incremental preset yet).
local function store_color_preset(display, name, quiet)
    local existing = find_color_preset_by_name(name)
    if existing then
        local ok, err = merge_color_preset(existing)
        if ok then return true, existing end
    end
    local ok, idx, err = store_new_color_preset(name)
    if not ok then
        if not quiet then
            MessageBox({ title="Preset Save Failed",
                message=string.format("Could not store preset '%s':\n\n%s", name, tostring(err)),
                display_handle=display, buttons={"OK"} })
        end
        return false, nil
    end
    return true, idx
end

-- Snapshot of the active calibration pass for auto-saving Color presets on
-- cancel/abort. preset_snapshot is owned by main() and passed in.
local function mark_preset_data(snapshot, kelvin, group)
    if not snapshot then return end
    snapshot.has_data = true
    if kelvin then snapshot.kelvin = kelvin end
    if group  then snapshot.group  = group  end
end

-- Save whatever color state is currently on the desk. Merges into the active
-- Kelvin preset when one exists, otherwise stores a new partial preset.
local function autosave_color_preset(display, snapshot, kelvin_preset, opts)
    opts = opts or {}
    if not snapshot or not snapshot.has_data then return false end
    if snapshot.saved and not opts.force then return false end

    if kelvin_preset and kelvin_preset.created then
        if snapshot.group then pcall(function() select_group(snapshot.group) end) end
        local ok = merge_color_preset(kelvin_preset.idx)
        if ok then
            snapshot.saved = true
            if not opts.quiet then
                MessageBox({ title = "Color Preset Updated",
                    message = string.format(
                        "Current state merged into Preset 4.%d \"%s\".",
                        kelvin_preset.idx, kelvin_preset.name),
                    display_handle = display, buttons = {"OK"} })
            end
        end
        return ok
    end

    if snapshot.group then
        pcall(function() select_group(snapshot.group) end)
    end

    local name = snapshot.kelvin and string.format("%dK", snapshot.kelvin) or "Lighttune"
    if opts.partial then name = name .. " (partial)" end

    local existing = find_color_preset_by_name(name)
    if existing then
        local ok = merge_color_preset(existing)
        if ok then
            snapshot.saved = true
            if kelvin_preset then
                kelvin_preset.idx = existing
                kelvin_preset.name = name
                kelvin_preset.created = true
            end
            if not opts.quiet then
                MessageBox({ title = "Color Preset Updated",
                    message = string.format(
                        "Current state merged into Preset 4.%d \"%s\".", existing, name),
                    display_handle = display, buttons = {"OK"} })
            end
        end
        return ok
    end

    local stored, idx = store_color_preset(display, name, opts.quiet)
    if stored then
        snapshot.saved = true
        if not opts.quiet then
            MessageBox({ title = "Color Preset Saved",
                message = string.format(
                    "Current color state stored as Preset 4.%d \"%s\".",
                    idx, name),
                display_handle = display, buttons = {"OK"} })
        end
    end
    return stored
end

-- One measure → assess → apply loop for a single target (whole group or one fixture).
-- state.bridge_active and state.session_abort are updated in place.
local function run_calibration_target(display, state, params)
    local ctx               = params.ctx
    local group             = params.group
    local goals             = params.goals
    local hist              = params.hist
    local config            = params.config
    local caps              = params.caps
    local fnum              = params.fnum
    local kelvin_preset     = params.kelvin_preset
    local cal_group         = params.cal_group
    local uncal_group       = params.uncal_group
    local preset_snapshot   = params.preset_snapshot
    local focus_preset    = params.focus_preset
    local bridge_active     = state.bridge_active
    local label             = fixture_label(ctx)

    local prev_x, prev_y = nil, nil
    local prev_channels = { tint = 50, cto = 0, ctb = 0, ctc_kelvin = nil }
    if caps and caps.tint_neutral then prev_channels.tint = caps.tint_neutral end
    if caps and caps.gdtf_cct then prev_channels.ctc_kelvin = caps.gdtf_cct end
    local stagnation = { best_score = nil, stagnant_count = 0 }
    local measured_out, correction_out = nil, nil
    local applied         = false
    local cancelled       = false
    local finalized       = false
    local last_apply_info = nil
    local attempts_total  = 0
    local measure_only    = not has_correctable_color(caps)

    crash_log.set_context({
        group = tostring(group),
        kelvin = goals and tostring(goals.cct or "") or "",
        phase = ctx and ctx.phase or "",
        fixture = fnum and tostring(fnum) or "",
    })
    crash_log.trace("info", "calibration_target_start", {
        measure_only = measure_only and "yes" or "no",
        bridge = bridge_active and "yes" or "no",
    })

    if measure_only then
        prepare_for_calibration(fnum, group, focus_preset)
        local measured

        if bridge_active then
            local m, merr = bridge_fetch_measurement(config)
            if m then
                measured = m
            else
                MessageBox({ title = fixture_context_title(ctx, label .. " – Bridge Unavailable"),
                    message = with_fixture_context(ctx,
                        "Auto-measurement failed:\n  "..tostring(merr)
                        .."\n\nSwitching to manual entry for this reading."),
                    display_handle = display, buttons = {"OK"} })
                bridge_active = false
                state.bridge_active = false
                measured = select(1, get_measurement_params(
                    display, 1, goals, hist, config, ctx, nil))
            end
        else
            measured = select(1, get_measurement_params(
                display, 1, goals, hist, config, ctx, nil))
        end

        if not measured then
            solo_selection_off(fnum)
            select_group(group)
            return { measured = nil, correction = nil, applied = false,
                attempts = 0, cancelled = true }
        end

        mark_preset_data(preset_snapshot, goals.cct, group)
        local passed = goals_met(measured, goals)
        finalize_fixture_save(display, ctx, measured, goals, fnum, group,
            1, passed,
            passed and nil or "did not meet goals (no color correction available)",
            kelvin_preset, cal_group, uncal_group, preset_snapshot,
            bridge_active, config, true)
        solo_selection_off(fnum)
        return {
            measured   = measured,
            correction = nil,
            applied    = false,
            attempts   = 1,
            cancelled  = false,
        }
    end

    for attempt = 1, MAX_ATTEMPTS_HARD do
        crash_log.trace("info", "prepare_calibration", { attempt = attempt })
        prepare_for_calibration(fnum, group, focus_preset)
        local measured

        if bridge_active then
            if attempt > 1 and last_apply_info then
                ok_or_auto_continue(display,
                    fixture_context_title(ctx,
                        "Re-measure" .. string.format(" (attempt %d)", attempt)),
                    with_fixture_context(ctx,
                        format_correction_fun_fact(last_apply_info)
                        .. "Taking the next bridge reading…"),
                    true, config, nil, format_correction_summary_line(last_apply_info))
            end
            local m, merr = bridge_fetch_measurement(config)
            if m then
                measured = m
            else
                MessageBox({ title = fixture_context_title(ctx, label .. " – Bridge Unavailable"),
                    message = with_fixture_context(ctx,
                        "Auto-measurement failed:\n  "..tostring(merr)
                        .."\n\nSwitching to manual entry for this target."),
                    display_handle = display, buttons = {"OK"} })
                bridge_active = false
                state.bridge_active = false
                measured = select(1, get_measurement_params(
                    display, attempt, goals, hist, config, ctx, last_apply_info))
            end
        else
            measured = select(1, get_measurement_params(
                display, attempt, goals, hist, config, ctx, last_apply_info))
        end

        if not measured then
            cancelled = true
            solo_selection_off(fnum)
            select_group(group)
            autosave_color_preset(display, preset_snapshot, kelvin_preset, { partial = true })
            state.session_abort = true
            break
        end
        mark_preset_data(preset_snapshot, goals.cct, group)
        measured_out = measured
        attempts_total = attempts_total + 1

        if bridge_active then
            Echo(string.format(
                "Lighttune [%s] attempt %d: %s",
                fixture_context_title(ctx, label),
                attempt,
                measured_metrics_summary(measured, goals)))
        end

        if goals_met(measured, goals) then
            finalize_fixture_save(display, ctx, measured, goals, fnum, group,
                attempt, true, nil, kelvin_preset, cal_group, uncal_group,
                preset_snapshot, bridge_active, config)
            finalized = true
            break
        end

        local score = error_score(measured, goals)
        stagnation = update_stagnation(stagnation, measured, score)

        local correction = color_math.get_correction(
            goals.cct, goals.duv, measured.cct, measured.duv, prev_x, prev_y)
        correction_out = correction

        if is_stagnated(stagnation, MAX_STAGNANT) then
            local plateau_reason = stagnation.reading_plateau
                and "readings unchanged (within meter repeatability)"
                or stagnation.score_plateau
                and "error score unchanged — fixture not responding"
                or "no further improvement"
            if bridge_active then
                Echo(string.format(
                    "Lighttune [%s] stopping after %d attempt(s): %s",
                    fixture_context_title(ctx, label),
                    attempt,
                    plateau_reason))
            end
            finalize_fixture_save(display, ctx, measured, goals, fnum, group,
                attempt, false, plateau_reason, kelvin_preset,
                cal_group, uncal_group, preset_snapshot, bridge_active, config)
            finalized = true
            break
        end

        local apply
        if bridge_active then
            apply = true
        else
            apply = show_assessment(display, group, goals, measured, correction, attempt, caps, ctx)
        end

        if apply then
            local result = fnum
                and apply_calibration_to_fixture(fnum, correction, caps, prev_channels)
                or  apply_calibration_to_group(group, correction, caps, prev_channels)
            if result.success then
                applied = true
                mark_preset_data(preset_snapshot, goals.cct, group)
                if result.channels then
                    prev_channels = result.channels
                    if result.channels.ctc_kelvin then
                        prev_channels.ctc_kelvin = result.channels.ctc_kelvin
                    end
                end
                last_apply_info = {
                    correction = correction,
                    method     = result.method,
                    channels   = result.channels,
                    from_x     = prev_x,
                    from_y     = prev_y,
                    to_x       = correction.target_x,
                    to_y       = correction.target_y,
                }
                prev_x, prev_y = correction.target_x, correction.target_y
                if bridge_active then
                    Echo(string.format(
                        "Lighttune [%s] applied: %s",
                        fixture_context_title(ctx, label),
                        tostring(result.method or "correction")))
                    local detail = format_correction_fun_fact(last_apply_info)
                    if detail ~= "" then
                        echo_lighttune_block("Correction detail", detail)
                    end
                end
            else
                show_result(display, false, ctx, result.method, result.error_msg)
                crash_log.trace("warn", "apply_failed", {
                    method = tostring(result.method),
                    error = tostring(result.error_msg or ""),
                    group = tostring(group),
                    fixture = fnum and tostring(fnum) or "",
                    phase = ctx and ctx.phase or "",
                })
            end
        end

        if not bridge_active then
            if ask_group_done(display, ctx, attempt) then break end
        end

        if attempt == MAX_ATTEMPTS_HARD then
            finalize_fixture_save(display, ctx, measured, goals, fnum, group,
                attempt, false, "attempt limit reached", kelvin_preset,
                cal_group, uncal_group, preset_snapshot, bridge_active, config)
            finalized = true
        end
    end

    if measured_out and not finalized then
        finalize_fixture_save(display, ctx, measured_out, goals, fnum, group,
            attempts_total, goals_met(measured_out, goals),
            goals_met(measured_out, goals) and nil or "operator finished early",
            kelvin_preset, cal_group, uncal_group, preset_snapshot, bridge_active, config)
        finalized = true
    end

    solo_selection_off(fnum)

    return {
        measured  = measured_out,
        correction = correction_out,
        applied   = applied,
        attempts  = attempts_total,
        cancelled = cancelled,
    }
end

-- Resolve the operator's Sekonic focus position preset (session-wide, optional).
-- config.focus_preset skips the prompt. Pan/tilt are never changed without a preset.
local function resolve_focus_preset(display, config)
    if config and config.focus_preset and config.focus_preset ~= "" then
        return normalize_focus_preset_id(config.focus_preset)
    end
    local r = MessageBox({ title = "Focus Position Preset (optional)",
        message = "If you have a position preset with fixtures aimed at the\n"
              .. "Sekonic, enter it here (e.g.  2.12  or  12  for Preset 2.12).\n\n"
              .. "Only pan/tilt/XYZ are taken from that preset.\n"
              .. "Dimmer and color are handled by the plugin.\n\n"
              .. "Skip if fixtures are already aimed — the plugin will NOT\n"
              .. "move pan/tilt without a preset.",
        display_handle = display, input = true, buttons = {"Apply", "Skip"} })
    if r == nil or r == 2 then return nil end
    local id = normalize_focus_preset_id(tostring(r))
    if not id then return nil end
    return id
end

--------------------------------------------------------------------------------
-- SECTION 5: DATA LOGGING
--
-- io.popen() and os.execute() are NOT available in GrandMA3 Lua.
-- get_sep()/get_plugin_dir() are defined near the top of this file (used
-- by the domain module loader too); see the comment there for why they
-- don't use GetPath(Enums.PathType.PluginLibrary).
-- Community upload to GitHub requires HTTPS; only lua.ftp (plain FTP) is
-- documented in the GrandMA3 Lua environment. Fixture data is therefore saved
-- locally only. To share data with the community, export fixture_log.json
-- manually and submit it via the project's GitHub page.
--
-- The data/ directory must exist inside the plugin folder (it is part of the
-- plugin package). No runtime directory creation is performed.
--------------------------------------------------------------------------------

-- Returns the path to the data directory (plugin_dir/data).
local function get_data_dir()
    local dir = get_plugin_dir()
    if not dir then return nil end
    return dir .. get_sep() .. "data"
end

-- Read config.json. Returns config table or nil.
-- Supported fields: github_username, bridge_ip, bridge_port, bridge_api_key,
-- focus_preset, open_bridge_browser, bridge_auto_continue_sec.
local function load_config()
    local dir = get_plugin_dir()
    if not dir then return nil end
    local path = dir .. get_sep() .. "config.json"
    local f = io.open(path, "r"); if not f then return nil end
    local content = f:read("*a"); f:close()
    local username       = content:match('"github_username"%s*:%s*"([^"]+)"')
    local bridge_ip      = content:match('"bridge_ip"%s*:%s*"([^"]+)"')
    local bridge_port    = tonumber(content:match('"bridge_port"%s*:%s*(%d+)'))
    local bridge_api_key = content:match('"bridge_api_key"%s*:%s*"([^"]*)"')
    local focus_preset   = content:match('"focus_preset"%s*:%s*"([^"]*)"')
    local open_browser   = content:match('"open_bridge_browser"%s*:%s*(%a+)')
    local auto_continue  = tonumber(content:match('"bridge_auto_continue_sec"%s*:%s*(%d+)'))
    return {
        github_username         = username,
        bridge_ip               = bridge_ip,
        bridge_port             = bridge_port or 8765,
        bridge_api_key          = bridge_api_key,
        focus_preset            = focus_preset,
        open_bridge_browser     = (open_browser == "true"),
        bridge_auto_continue_sec = auto_continue,
    }
end

local function github_username_valid(username)
    return username and username ~= "" and username ~= "your_github_username"
end

-- Persist github_username into config.json at the plugin root.
local function save_github_username(username)
    username = tostring(username or ""):match("^%s*(.-)%s*$")
    local path = get_plugin_dir() .. get_sep() .. "config.json"
    local content = ""
    local f = io.open(path, "r")
    if f then content = f:read("*a"); f:close() end
    local escaped = username:gsub("\\", "\\\\"):gsub('"', '\\"')
    if content == "" or not content:match("{") then
        if username == "" then
            content = '{\n  "github_username": ""\n}\n'
        else
            content = string.format('{\n  "github_username": "%s"\n}\n', escaped)
        end
    elseif content:match('"github_username"') then
        content = content:gsub(
            '"github_username"%s*:%s*"[^"]*"',
            '"github_username": "' .. escaped .. '"', 1)
    else
        content = content:gsub("{", '{\n  "github_username": "' .. escaped .. '",', 1)
    end
    local wf = io.open(path, "w")
    if not wf then return false end
    wf:write(content)
    wf:close()
    return true
end

local function github_username_label(config)
    if github_username_valid(config and config.github_username) then
        return config.github_username
    end
    return "(not set)"
end

-- Edit and save GitHub username from Settings (returns true when saved or cleared).
local function prompt_edit_github_username(display, config)
    config = config or {}
    local current = github_username_label(config)
    local r = MessageBox({
        title   = "GitHub Username",
        message = string.format(
            "Current: %s\n\n"
            .. "Enter your GitHub username for fixture log attribution.\n"
            .. "It is saved to config.json and used as contributor\n"
            .. "on each measurement.\n\n"
            .. "Clear removes the saved username.",
            current),
        display_handle = display,
        input = true,
        buttons = {"Save", "Clear", "Cancel"},
    })
    if r == nil or r == 3 then return false end
    if r == 2 then
        if save_github_username("") then
            config.github_username = nil
            Echo("Lighttune: cleared GitHub username in config.json")
            MessageBox({ title = "Settings",
                message = "GitHub username cleared.\n\nCalibration will use \"local\" unless you set a username.",
                display_handle = display, buttons = {"OK"} })
            return true
        end
        MessageBox({ title = "Settings",
            message = "Could not write config.json.\n\nCheck that the plugin folder is writable.",
            display_handle = display, buttons = {"OK"} })
        return false
    end
    local username = tostring(r):match("^%s*(.-)%s*$")
    if username == "" then
        MessageBox({ title = "GitHub Username",
            message = "Username cannot be empty.\n\nUse Clear to remove a saved username.",
            display_handle = display, buttons = {"OK"} })
        return false
    end
    if save_github_username(username) then
        config.github_username = username
        Echo("Lighttune: saved GitHub username to config.json")
        MessageBox({ title = "Settings",
            message = string.format("GitHub username saved:\n\n  %s", username),
            display_handle = display, buttons = {"OK"} })
        return true
    end
    config.github_username = username
    Echo("Lighttune: could not write config.json — username kept for this session only")
    MessageBox({ title = "Settings",
        message = string.format(
            "Using username for this session:\n\n  %s\n\n"
            .. "Could not write config.json — check that the plugin folder is writable.",
            username),
        display_handle = display, buttons = {"OK"} })
    return true
end

local function show_settings_menu(display, config)
    while true do
        local r = MessageBox({
            title   = "Settings",
            message = string.format(
                "GitHub username: %s\n\n"
                .. "Used as contributor on fixture measurements.\n"
                .. "Bridge fixture history shows this in the By column.",
                github_username_label(config)),
            display_handle = display,
            buttons = {"Edit GitHub Username", "Back"},
        })
        if r == nil or r == 2 then return end
        prompt_edit_github_username(display, config)
    end
end

-- Prompt once when github_username is missing; optionally save to config.json.
local function resolve_github_username(display, config)
    config = config or {}
    if github_username_valid(config.github_username) then
        return config.github_username
    end
    local r = MessageBox({
        title   = "GitHub Username",
        message = "Enter your GitHub username for fixture log attribution.\n\n"
               .. "It is stored as contributor on each measurement and saved\n"
               .. "to config.json when you press Save.\n\n"
               .. "You can also set this anytime under Settings in the main menu.\n\n"
               .. "Skip to use \"local\" for this session only.",
        display_handle = display,
        input = true,
        buttons = {"Save", "Skip"},
    })
    if r == nil or r == 2 then return "local" end
    local username = tostring(r):match("^%s*(.-)%s*$")
    if username == "" then return "local" end
    if save_github_username(username) then
        config.github_username = username
        Echo("Lighttune: saved GitHub username to config.json")
    else
        config.github_username = username
        Echo("Lighttune: using GitHub username this session (could not write config.json)")
    end
    return username
end

bridge_configured = function(config)
    return config and config.bridge_ip and config.bridge_ip ~= ""
end
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

-- Push the full local fixture_log.json to the bridge webapp (best-effort).
push_fixture_log_to_bridge = function(config, quiet)
    if not bridge_configured(config) then
        return false, "no_bridge_configured"
    end
    local ok, err = pcall(function()
        local path = get_data_dir() .. get_sep() .. "fixture_log.json"
        local rf = io.open(path, "r")
        if not rf then error("no local fixture_log.json") end
        local content = rf:read("*a")
        rf:close()
        if not content or content:match("^%s*$") then error("fixture log is empty") end
        local result = bridge_client.sync_fixture_log(config, content)
        if not result or not result.ok then
            error(tostring(result and result.message or "sync_failed"))
        end
    end)
    if ok then
        if not quiet then Echo("Lighttune: fixture history synced to bridge") end
        return true, nil
    end
    if not quiet then
        Echo("Lighttune: could not sync fixture history to bridge — " .. tostring(err))
    end
    return false, err
end

local function sync_fixture_log_to_bridge(config)
    push_fixture_log_to_bridge(config, true)
end

open_fixture_history_in_bridge = function(display, config)
    if not bridge_configured(config) then
        MessageBox({ title = "Fixture History",
            message = "No bridge configured.\n\n"
                  .. "Add bridge_ip to config.json to view history in the bridge web UI.",
            display_handle = display, buttons = {"OK"} })
        return
    end
    push_fixture_log_to_bridge(config, false)
    local opened, url = open_bridge_browser(config, "fixtures")
    if opened then
        Echo("Lighttune: opened fixture history in bridge — " .. tostring(url))
        return
    end
    MessageBox({ title = "Fixture History — Bridge",
        message = string.format(
            "History uploaded to the bridge.\n\n"
            .. "Open this URL on a device with a browser:\n\n  %s\n\n"
            .. "Use FIXTURE LOG on the dashboard if this link fails.",
            url or "?"),
        display_handle = display, buttons = {"OK"} })
end

-- Save fixture measurement locally and mirror to the bridge when configured.
-- Community upload to GitHub is not available in GrandMA3 Lua (requires HTTPS;
-- only lua.ftp / plain FTP is documented). Export fixture_log.json manually
-- to share data with the community.
local function log_fixture_data(display, db_entry, config)
    if not db_entry.make or not db_entry.model then return end
    save_fixture_log_local(db_entry)
    sync_fixture_log_to_bridge(config)
end

--------------------------------------------------------------------------------
-- SECTION 6: MAIN ENTRY POINT
--------------------------------------------------------------------------------

function Main(display, ...)
    -- Survives the pcall below so cancel/abort/error can still auto-save presets.
    local preset_snapshot = { kelvin = nil, group = nil, has_data = false, saved = false }

    crash_log.init(get_data_dir, get_sep)
    local host_os = "unknown"
    pcall(function() host_os = HostOS() end)
    crash_log.trace("info", "plugin_start", { host = host_os })

    local ok, err = pcall(function()

        local config = load_config() or {}

        -- ── Main menu ─────────────────────────────────────────────────────
        local menu
        while true do
            menu = MessageBox({
                title   = "SekonicCalibrator v0.5",
                message = "Lighttune – GrandMA3 Color Calibration\n\n"
                        .."Calibrate fixture groups using your\n"
                        .."Sekonic spectromaster (C-700, C-800, or C-7000).\n\n"
                        .."What would you like to do?",
                display_handle = display,
                buttons = {"Start Calibration","Open Bridge","Fixture History","Settings","Crash Log","Cancel"},
            })
            if menu==nil or menu==6 then return end
            if menu==2 then
                prompt_open_bridge(display, config, "dashboard")
            elseif menu==4 then
                show_settings_menu(display, config)
            elseif menu==5 then
                show_crash_log(display)
            else
                break
            end
        end

        -- data_dir is provided by get_data_dir(); no mkdir needed –
        -- the data/ directory must exist as part of plugin installation.
        local data_dir = get_data_dir()

        if menu==3 then
            if bridge_configured(config) then
                local view = MessageBox({ title = "Fixture History",
                    message = "View logged measurements on the console or in the bridge web UI?\n\n"
                           .. "Bridge shows the full table with contributor names.",
                    display_handle = display,
                    buttons = {"Console", "Bridge Web", "Cancel"} })
                if view == nil or view == 3 then return end
                if view == 2 then
                    open_fixture_history_in_bridge(display, config)
                    return
                end
            end
            show_fixture_history(display, data_dir)
            return
        end

        config.github_username = resolve_github_username(display, config)

        -- ── Session goals (now: one or more Kelvin targets) ────────────────
        local bridge_meter, bridge_meter_name = resolve_meter_from_bridge(config)
        local goals_base = get_session_goals(display, config, bridge_meter)
        if not goals_base then return end

        -- ── Preflight bridge check (replaces the old Bridge Status menu) ──
        local bridge_active, bridge_note = preflight_bridge_check(display, config, goals_base.meter)
        if bridge_meter_name and bridge_meter then
            local auto_note = string.format("Meter: %s (from bridge)", bridge_meter_name)
            bridge_note = bridge_note and (auto_note .. "\n\n" .. bridge_note) or auto_note
        end
        if bridge_note then
            MessageBox({ title = bridge_active and "Bridge Ready" or "Bridge Not Available",
                message = bridge_note, display_handle = display, buttons = {"OK"} })
        end

        local session_log = {}

        -- Load local fixture records for pre-fill and session updates
        local fixture_records = {}
        do
            local sep = get_sep()
            local f = io.open(data_dir..sep.."fixture_log.json","r")
            if f then fixture_records=select(1, fixture_db.json_parse_db_array(f:read("*a"))); f:close() end
        end

        local group_list = get_group_list_input(display)
        if not group_list then return end

        local kelvin_str = table.concat(goals_base.cct_list, ",")
        local group_str = table.concat(group_list, ",")
        crash_log.set_context({ session = "calibration", kelvin = kelvin_str })
        crash_log.trace("info", "session_start", {
            groups = group_str,
            kelvin_targets = kelvin_str,
            bridge = bridge_active and "yes" or "no",
        })

        open_system_monitor_view(display)

        local focus_preset = resolve_focus_preset(display, config)
        if focus_preset then
            Echo(string.format(
                "Lighttune: focus preset %s — pan/tilt from preset only", focus_preset))
            crash_log.trace("info", "focus_preset_session", { preset = focus_preset })
        else
            Echo("Lighttune: no focus preset — pan/tilt unchanged")
            crash_log.trace("info", "focus_preset_session", { preset = "none" })
        end

        local session_abort = false
        local cal_group   = init_named_group_tracker("CAL")
        local uncal_group = init_named_group_tracker("UNCAL")
        if cal_group.created then
            Echo(string.format("Lighttune: merging calibrated fixtures into Group %d \"CAL\"", cal_group.idx))
        end
        if uncal_group.created then
            Echo(string.format("Lighttune: merging uncalibrated fixtures into Group %d \"UNCAL\"", uncal_group.idx))
        end

        -- ── Outer loop: Kelvin target by Kelvin target ─────────────────────
        for kelvin_idx, target_cct in ipairs(goals_base.cct_list) do
            if session_abort then break end

            preset_snapshot.kelvin = target_cct
            preset_snapshot.saved  = false

            local kelvin_preset = init_kelvin_preset_tracker(target_cct)
            if kelvin_preset.created then
                Echo(string.format(
                    "Lighttune: merging color into existing Preset 4.%d \"%s\"",
                    kelvin_preset.idx, kelvin_preset.name))
            end

            local goals = {
                meter=goals_base.meter, mode=goals_base.mode, ref_group=goals_base.ref_group,
                cct=target_cct, duv=goals_base.duv,
                cri=goals_base.cri, r9=goals_base.r9, tlci=goals_base.tlci,
            }

            if #goals_base.cct_list > 1 then
                MessageBox({ title = string.format("Target %d of %d", kelvin_idx, #goals_base.cct_list),
                    message = string.format("Now calibrating to %dK.", target_cct),
                    display_handle = display, buttons = {"OK"} })
            end

            local kelvin_group_names = {}

            -- ── Group loop (batch selected upfront) ───────────────────────
            for group_idx, group in ipairs(group_list) do
                if session_abort then break end

                preset_snapshot.kelvin = target_cct
                preset_snapshot.group  = group

                if #group_list > 1 then
                    MessageBox({ title = string.format("Group %d of %d", group_idx, #group_list),
                        message = string.format("Now calibrating group: %s", group),
                        display_handle = display, buttons = {"OK"} })
                end

                select_group(group)
                crash_log.set_context({ group = group, kelvin = target_cct })
                local fixture_make, fixture_model = get_fixture_model_from_desk(group)
                local caps = read_capabilities_from_patch(group)
                Echo("Lighttune: " .. gdtf_caps.summary(caps))
                crash_log.trace("info", "fixture_caps", {
                    source = caps.source or "?",
                    summary = gdtf_caps.summary(caps),
                    mode = caps.gdtf_mode or "",
                    cct_range = caps.ctc_kelvin_min and caps.ctc_kelvin_max
                        and string.format("%d-%dK", caps.ctc_kelvin_min, caps.ctc_kelvin_max) or "",
                })
                goals.gdtf_cri = caps and caps.gdtf_cri or nil

                local hist = (fixture_make and fixture_model)
                    and fixture_db.find_best_for_fixture(fixture_records, fixture_make, fixture_model, goals.cct)
                    or nil

                if hist then
                    local tx, ty, ref_date = apply_historical_prefill(display, group, hist, goals)
                    if tx then
                        local result = calibrate_group(group, tx, ty)
                        if result.success then
                            mark_preset_data(preset_snapshot, goals.cct, group)
                            MessageBox({ title="Pre-applied",
                                message=string.format(
                                    "Best known correction applied to Group %s.\n"
                                    .."Data from: %s\n\nNow take your first Sekonic reading.",
                                    group, ref_date or "prior session"),
                                display_handle=display, buttons={"OK"} })
                        end
                    end
                end

                -- ── Two-phase calibration: group pass, then per-fixture solo ──
                local fixture_nums = get_group_fixture_numbers(group)
                do
                    local ids = {}
                    for _, n in ipairs(fixture_nums) do ids[#ids + 1] = tostring(n) end
                    crash_log.trace("info", "fixture_list", {
                        count = #fixture_nums,
                        fixtures = table.concat(ids, ","),
                    })
                end

                local group_last_measured   = nil
                local group_last_correction = nil
                local group_applied_once    = false
                local group_pass_attempts   = 0
                local group_solo_attempts   = 0
                local group_attempts_total  = 0
                local group_cancelled       = false
                local cal_state = { bridge_active = bridge_active, session_abort = false }

                -- Phase 1: entire group
                if #fixture_nums > 0 then
                    ok_or_auto_continue(display, "Phase 1 – Group Pass",
                        string.format(
                            "Calibrating entire group \"%s\" as one block first.\n\n"
                            .. "%d fixture(s) will be calibrated individually after this.",
                            group, #fixture_nums),
                        bridge_active, config)
                end

                local group_ctx = {
                    group        = group,
                    fnum         = nil,
                    phase        = "group",
                    type_make    = fixture_make,
                    type_model   = fixture_model,
                    groups_index = group_idx,
                    groups_total = #group_list,
                }

                local group_result = run_calibration_target(display, cal_state, {
                    ctx = group_ctx, group = group, goals = goals, hist = hist,
                    config = config, caps = caps, fnum = nil,
                    focus_preset = focus_preset,
                    kelvin_preset = kelvin_preset, cal_group = cal_group,
                    uncal_group = uncal_group, preset_snapshot = preset_snapshot,
                })

                bridge_active = cal_state.bridge_active
                if cal_state.session_abort then session_abort = true end

                if group_result.cancelled or session_abort then
                    group_cancelled = true
                else
                    group_last_measured   = group_result.measured
                    group_last_correction = group_result.correction
                    if group_result.applied then group_applied_once = true end
                    group_pass_attempts   = group_result.attempts or 0
                    group_attempts_total  = group_pass_attempts
                end

                -- Phase 2: each fixture solo — reuse list captured before group pass
                -- (selection/solo state after Phase 1 often breaks re-enumeration).
                if not group_cancelled and not session_abort then
                    if #fixture_nums == 0 then
                        fixture_nums = get_group_fixture_numbers(group)
                    end

                    if #fixture_nums == 0 then
                        crash_log.trace("warn", "individual_pass_skipped", { group = group })
                        ok_or_auto_continue(display, "Individual Pass Skipped",
                            string.format(
                                "Could not read fixture list for group \"%s\".\n\n"
                                .. "Group pass is complete; per-fixture solo was skipped.\n"
                                .. "Try re-selecting the group in Patch and run again.",
                                group),
                            bridge_active, config)
                    else
                        ok_or_auto_continue(display, "Phase 2 – Individual Fixtures",
                            string.format(
                                "Group pass complete.\n\n"
                                .. "Now calibrating each of %d fixture(s) individually (solo).",
                                #fixture_nums),
                            bridge_active, config)

                        for fi, fnum in ipairs(fixture_nums) do
                            if session_abort or cal_state.session_abort then break end

                            local fixture_name = get_fixture_name_from_desk(fnum)
                            local fixture_caps = read_capabilities_from_fixture(fnum) or caps
                            local ctx = {
                                group        = group,
                                fnum         = fnum,
                                index        = fi,
                                total        = #fixture_nums,
                                name         = fixture_name,
                                phase        = "individual",
                                type_make    = fixture_make,
                                type_model   = fixture_model,
                                groups_index = group_idx,
                                groups_total = #group_list,
                            }

                            local result = run_calibration_target(display, cal_state, {
                                ctx = ctx, group = group, goals = goals, hist = hist,
                                config = config, caps = fixture_caps, fnum = fnum,
                                focus_preset = focus_preset,
                                kelvin_preset = kelvin_preset, cal_group = cal_group,
                                uncal_group = uncal_group, preset_snapshot = preset_snapshot,
                            })

                            bridge_active = cal_state.bridge_active
                            if cal_state.session_abort then session_abort = true end

                            if result.cancelled or session_abort then
                                group_cancelled = true
                                break
                            end

                            group_last_measured   = result.measured or group_last_measured
                            group_last_correction = result.correction or group_last_correction
                            if result.applied then group_applied_once = true end
                            group_solo_attempts   = group_solo_attempts + (result.attempts or 0)
                            group_attempts_total  = group_pass_attempts + group_solo_attempts
                        end
                    end
                end

                -- Restore the whole-group selection so the desk is left in a
                -- sensible state for the operator once every fixture is done.
                select_group(group)

                if not group_cancelled and group_last_measured then
                    local db_entry = {
                        make        = fixture_make,
                        model       = fixture_model,
                        kelvin      = goals.cct,
                        date        = os.date("%Y-%m-%d"),
                        contributor = config and config.github_username or "local",
                        cct         = group_last_measured.cct,
                        duv         = group_last_measured.duv,
                        cri         = group_last_measured.cri,
                        r9          = group_last_measured.r9,
                        tlci        = group_last_measured.tlci,
                    }
                    log_fixture_data(display, db_entry, config)
                    if fixture_make and fixture_model then
                        fixture_db.append_fixture_record(fixture_records, db_entry)
                    end

                    table.insert(session_log, {
                        group              = group,
                        kelvin             = goals.cct,
                        make               = fixture_make,
                        model              = fixture_model,
                        measured           = group_last_measured,
                        correction         = group_last_correction,
                        applied            = group_applied_once,
                        attempt            = group_attempts_total,
                        attempt_group      = group_pass_attempts,
                        attempt_individual = group_solo_attempts,
                    })
                    table.insert(kelvin_group_names, group)
                end

            end

            -- Fallback: auto-save only if no incremental preset was built fixture-by-fixture.
            if #kelvin_group_names > 0 and not kelvin_preset.created then
                preset_snapshot.group = kelvin_group_names[#kelvin_group_names]
                mark_preset_data(preset_snapshot, goals.cct, preset_snapshot.group)
                autosave_color_preset(display, preset_snapshot, kelvin_preset, { quiet = true })
            end
        end

        sync_fixture_log_to_bridge(config)
        crash_log.trace("info", "session_complete", { groups = group_str })
        show_session_summary(display, session_log, goals_base)
    end)

    if preset_snapshot.has_data and not preset_snapshot.saved then
        autosave_color_preset(display, preset_snapshot, nil, { partial = true })
    end

    if not ok then
        local log_path = crash_log.log_exception(err, { where = "main" })
        MessageBox({ title="Unexpected Error",
            message="An unexpected error occurred:\n\n"..tostring(err)
                  .."\n\nDetails saved to:\n"..tostring(log_path or "data/crash_log.jsonl")
                  .."\n\nOpen Crash Log from the plugin menu to review recent events.",
            display_handle=display, buttons={"OK"} })
    end
end

return Main
