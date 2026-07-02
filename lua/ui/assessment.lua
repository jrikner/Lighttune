-- ui/assessment.lua — quality assessment and correction summary (Phase 6)

local color_math = require("color_math")
local goal_eval  = require("goals")
local session_ui = require("ui.session")

local M = {}

local QUALITY = goal_eval.QUALITY

function M.show_assessment(display, group, session_goals, measured, correction, attempt, caps)
    local cri_rating  = color_math.rate_quality(measured.cri, QUALITY.CRI)
    local r9_rating   = color_math.rate_quality(measured.r9,  QUALITY.R9)
    local tlci_rating = measured.tlci and color_math.rate_quality(measured.tlci, QUALITY.TLCI) or "n/a"
    local duv_rating  = color_math.rate_duv(measured.duv)

    local cri_gs  = goal_eval.goal_status_str(measured.cri,  session_goals.cri)
    local r9_gs   = goal_eval.goal_status_str(measured.r9,   session_goals.r9)
    local tlci_gs = measured.tlci and goal_eval.goal_status_str(measured.tlci, session_goals.tlci) or ""

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

    local hints = {}
    local duv_off = math.abs(measured.duv) > QUALITY.DUV.good

    if duv_off then
        local extreme = math.abs(measured.duv) > 0.020
        if caps then
            if caps.has_tint and not extreme then
                local dir = measured.duv>0 and "negative (toward magenta)" or "positive (toward green)"
                hints[#hints+1]=string.format(
                    "  Tint channel: Shift toward %s to correct Duv %+.4f",
                    dir, measured.duv)
            elseif caps.has_color_wheel_filters then
                local slot_dir = measured.duv>0 and "Minus Green" or "Plus Green"
                hints[#hints+1]="  Color wheel: Use the "..slot_dir.." filter slot if available"
                local gh = color_math.gel_hint(measured.duv)
                if gh then hints[#hints+1]="  Physical gel (if no matching slot): "..gh end
            else
                local gh = color_math.gel_hint(measured.duv)
                if gh then hints[#hints+1]="  Gel (no Tint channel/filter wheel available): "..gh end
            end
            if extreme and caps.has_tint then
                hints[#hints+1]="  Physical gel also required – Duv extreme, beyond Tint range"
                local gh = color_math.gel_hint(measured.duv)
                if gh then hints[#hints+1]="  "..gh end
            end
        else
            local gh = color_math.gel_hint(measured.duv)
            if gh then hints[#hints+1]="  Physical gel: "..gh end
        end
    end

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

    if measured.cri < 85 then
        hints[#hints+1]="  CRI: Cannot be improved via console – try a different"
        hints[#hints+1]="       fixture or enable the fixture's high-CRI mode" end
    if measured.r9 < 65 then
        hints[#hints+1]="  R9:  Low R9 is a spectral issue – consider a high-R9"
        hints[#hints+1]="       fixture or add a warming gel" end

    local hints_str = #hints>0
        and ("\n== Hints ==\n\n"..table.concat(hints,"\n").."\n") or ""

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
        group, attempt, session_ui.goals_summary_line(session_goals),
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

return M
