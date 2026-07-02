-- ui/bridge.lua — Bridge Status + setup wizard UI (Phase 6)

local bridge_client = require("bridge_client")

local M = {}

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

local function run_trigger_discovery(display, config)
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

local function run_bridge_setup(display, config)
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
        run_trigger_discovery(display, config)
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

function M.show_bridge_status(display, config)
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
            run_trigger_discovery(display, config)
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

return M

