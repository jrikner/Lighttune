-- calibration.lua — calibration orchestration (outer/inner loops) (Phase 6)

local color_math     = require("color_math")
local fixture_db     = require("fixture_db")
local goal_eval      = require("goals")
local patch_api      = require("patch_api")
local fixture_apply  = require("fixture_apply")
local measurement_ui = require("ui.measurement")
local assessment_ui  = require("ui.assessment")
local session_ui     = require("ui.session")
local dialogs        = require("ui.dialogs")

local M = {}

local MODE_REFERENCE = "reference"
local METER_C7000    = "c7000"

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

    local ref = hist.best_duv or hist.entries[1]
    if not ref or not ref.cct or not ref.duv then return end

    local correction = color_math.get_correction(session_goals.cct, session_goals.duv, ref.cct, ref.duv)
    return correction.target_x, correction.target_y, ref.date
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

local function load_fixture_records(data_dir, sep)
    local records = {}
    local f = io.open(data_dir..sep.."fixture_log.json","r")
    if f then records=select(1, fixture_db.json_parse_db_array(f:read("*a"))); f:close() end
    return records
end

local function save_fixture_log_local(data_dir, sep, db_entry)
    local ok = pcall(function()
        local path = data_dir .. sep .. "fixture_log.json"
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

function M.run(display, deps)
    local config    = deps.config or {}
    local data_dir  = deps.data_dir
    local sep       = deps.sep or "/"

    local session_goals = session_ui.get_session_goals(display)
    if not session_goals then return end

    local session_log = {}

    local fixture_records = load_fixture_records(data_dir, sep)

    repeat
        local group = get_group_input(display)
        if not group then break end

        local fixture_make, fixture_model = get_fixture_model_input(display, group)

        local caps = patch_api.read_capabilities_from_patch(group)

        session_goals.gdtf_cri = caps and caps.gdtf_cri or nil

        local hist = (fixture_make and fixture_model)
            and fixture_db.find_best_for_fixture(fixture_records, fixture_make, fixture_model, session_goals.cct)
            or nil

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

        local MAX_AUTO_ATTEMPTS = 3
        local bridge_active = config and config.bridge_ip
                                      and config.bridge_ip ~= ""
                                      and session_goals.meter == METER_C7000
        local loop_done     = false
        local loop_count    = 0
        local user_manual   = false

        repeat
            attempt = attempt + 1

            local measured, used_bridge

            if bridge_active and not user_manual and attempt > 1 then
                local m, err = measurement_ui._bridge_fetch_measurement(config)
                if m then
                    used_bridge = true
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
                        user_manual = true
                        measured, used_bridge =
                            measurement_ui.get_measurement_params(display, attempt, session_goals, hist, config)
                    else
                        measured = m
                    end
                else
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
                            measurement_ui.get_measurement_params(display, attempt, session_goals, hist, config)
                    else
                        attempt = attempt - 1
                    end
                end
            else
                measured, used_bridge =
                    measurement_ui.get_measurement_params(display, attempt, session_goals, hist, config)
                if bridge_active and not used_bridge then user_manual = true end
            end

            if loop_done then break end
            if not measured then loop_done = true; break end
            last_measured = measured

            local correction = color_math.get_correction(
                session_goals.cct, session_goals.duv, measured.cct, measured.duv)
            last_correction = correction

            if bridge_active and not user_manual then
                loop_count = loop_count + 1

                if goal_eval.goals_met(measured, session_goals) then
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
                    local apply = assessment_ui.show_assessment(
                        display, group, session_goals, measured, correction, attempt, caps)
                    if apply then
                        local result = fixture_apply.calibrate_group(
                            group, correction.target_x, correction.target_y)
                        if result.success then
                            applied_once = true
                        else
                            dialogs.show_result(display, false, group,
                                result.method, result.error_msg)
                        end
                    end

                    if loop_count >= MAX_AUTO_ATTEMPTS then
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
                            loop_done = true
                        elseif r == 3 then
                            last_measured = nil
                            loop_done = true
                        else
                            loop_count = 0
                        end
                    end
                end
            else
                local apply = assessment_ui.show_assessment(
                    display, group, session_goals, measured, correction, attempt, caps)
                if apply then
                    local result = fixture_apply.calibrate_group(
                        group, correction.target_x, correction.target_y)
                    dialogs.show_result(display, result.success, group,
                        result.method, result.error_msg)
                    if result.success then applied_once = true end
                end
                loop_done = ask_group_done(display, group, attempt)
            end

        until loop_done

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
            save_fixture_log_local(data_dir, sep, db_entry)

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

    session_ui.show_session_summary(display, session_log, session_goals)
end

return M

