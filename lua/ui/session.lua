-- ui/session.lua — session goals and summary dialogs (Phase 6)

local color_math = require("color_math")
local goal_eval  = require("goals")
local dialogs    = require("ui.dialogs")

local M = {}

local GOAL_MAX  = goal_eval.GOAL_MAX
local GOAL_MIN  = goal_eval.GOAL_MIN
local GOAL_SKIP = goal_eval.GOAL_SKIP
local CCT_MIN   = color_math.CCT_MIN
local CCT_MAX   = color_math.CCT_MAX
local DUV_MIN   = color_math.DUV_MIN
local DUV_MAX   = color_math.DUV_MAX

local CRI_MIN =  0
local CRI_MAX =  100

local MODE_TARGET    = "target"
local MODE_REFERENCE = "reference"

local METER_C700  = "c700"
local METER_C7000 = "c7000"

local function get_number_input(...)
    return dialogs.get_number_input(...)
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

function M.get_session_goals(display)
    local mc = MessageBox({
        title="Sekonic Meter Model",
        message="Which Sekonic meter are you using?\n\n"
              .."  C-700 / C-800  – CCT, Duv, CRI, R9  (no TLCI)\n"
              .."  C-7000         – CCT, Duv, CRI, R9, TLCI",
        display_handle=display, buttons={"C-700 / C-800","C-7000"} })
    if mc==nil then return nil end
    local meter = (mc==1) and METER_C700 or METER_C7000

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

function M.goals_summary_line(session_goals)
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

function M.show_session_summary(display, session_log, session_goals)
    if #session_log==0 then return end
    local lines = {
        string.format("== Session Summary  (%d group%s) ==\n", #session_log, #session_log==1 and "" or "s"),
        M.goals_summary_line(session_goals).."\n",
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

return M
