-- ui/measurement.lua — Sekonic measurement input (remote + manual) (Phase 6)

local color_math     = require("color_math")
local goal_eval      = require("goals")
local bridge_client  = require("bridge_client")
local dialogs        = require("ui.dialogs")

local M = {}

local GOAL_SKIP = goal_eval.GOAL_SKIP
local CCT_MIN   = color_math.CCT_MIN
local CCT_MAX   = color_math.CCT_MAX
local DUV_MIN   = color_math.DUV_MIN
local DUV_MAX   = color_math.DUV_MAX

local CRI_MIN =  0
local CRI_MAX =  100

local METER_C700  = "c700"
local METER_C7000 = "c7000"

local function format_bridge_error(err_result, config)
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

local function bridge_fetch_measurement(config)
    local result = bridge_client.fetch_measurement(config)
    if result.ok then return result.data end
    return nil, format_bridge_error(result, config)
end

function M.get_measurement_params(display, attempt, session_goals, hist, config)
    local suffix     = attempt>1 and string.format(" (attempt %d)", attempt) or ""
    local track_tlci = session_goals.tlci and session_goals.tlci.mode~=GOAL_SKIP
    local meter_name = (session_goals.meter==METER_C700) and "C-700/C-800" or "C-7000"

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
            end
        end
    elseif config and config.bridge_ip and config.bridge_ip ~= ""
       and session_goals.meter == METER_C700 and attempt == 1 then
    end

    local function prior(rec, field, fmt)
        if attempt==1 and rec and rec[field]~=nil then
            return string.format("\n  Prior best: "..fmt.." (%s)", rec[field], rec.date or "?")
        end
        return ""
    end

    local cct = dialogs.get_number_input(display,"Measured CCT"..suffix,
        string.format("CCT reading from Sekonic %s.\nRange: %d – %d K%s",
            meter_name, CCT_MIN, CCT_MAX,
            prior(hist and hist.best_duv, "cct", "%dK")),
        CCT_MIN, CCT_MAX)
    if not cct then return nil end

    local duv = dialogs.get_number_input(display,"Measured Duv"..suffix,
        string.format("Duv (\xce\x94uv) from Sekonic %s.\nRange: %g to %+g\n\n"
            .."+value = green  |  -value = magenta%s",
            meter_name, DUV_MIN, DUV_MAX,
            prior(hist and hist.best_duv, "duv", "%+.4f")),
        DUV_MIN, DUV_MAX)
    if not duv then return nil end

    local gdtf_cri_hint = (attempt==1 and session_goals.gdtf_cri)
        and string.format("\n  Manufacturer rated: %d", session_goals.gdtf_cri) or ""

    local cri = dialogs.get_number_input(display,"Measured CRI (Ra)"..suffix,
        string.format("CRI (Ra) from Sekonic %s.\nRange: %d – %d%s%s",
            meter_name, CRI_MIN, CRI_MAX,
            gdtf_cri_hint,
            prior(hist and hist.best_cri, "cri", "%d")),
        CRI_MIN, CRI_MAX)
    if not cri then return nil end

    local r9 = dialogs.get_number_input(display,"Measured R9"..suffix,
        string.format("R9 (deep red) from Sekonic %s.\nRange: %d – %d\n\n"
            .."Critical for skin tones and costumes on camera.%s",
            meter_name, CRI_MIN, CRI_MAX,
            prior(hist and hist.best_r9, "r9", "%d")),
        CRI_MIN, CRI_MAX)
    if not r9 then return nil end

    local tlci = nil
    if track_tlci then
        tlci = dialogs.get_number_input(display,"Measured TLCI"..suffix,
            string.format("TLCI from Sekonic C-7000.\nRange: %d – %d\n\n"
                .."Television Lighting Consistency Index.\nBroadcast ready: 90+%s",
                CRI_MIN, CRI_MAX,
                prior(hist and hist.best_tlci, "tlci", "%d")),
            CRI_MIN, CRI_MAX)
        if not tlci then return nil end
    end

    return { cct=cct, duv=duv, cri=cri, r9=r9, tlci=tlci }, false
end

M._bridge_fetch_measurement = bridge_fetch_measurement

return M
