-- bridge_client.lua — HTTP bridge client for Sekonic Pi bridge (Phase 5 ARCH-04)
-- Host-testable parse/classify helpers; no MA3 UI. Return-M contract.

local M = {}

-- Route timeouts (seconds) — D-81
M.TIMEOUT_STATUS       = 5
M.TIMEOUT_DISCOVER     = 12
M.TIMEOUT_CAPTURE      = 35
M.TIMEOUT_MEASURE      = 38
M.TIMEOUT_LEARN_TRIGGER = 120

-- Validation bounds (aligned with color_math)
M.CCT_MIN = 1667
M.CCT_MAX = 25000
M.DUV_MIN = -0.02
M.DUV_MAX =  0.02
M.CRI_MIN = 0
M.CRI_MAX = 100

local function json_field(body, key)
    if not body then return nil end
    return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
        or body:match('"' .. key .. '"%s*:%s*([^%s,}]+)')
end

function M.classify_http(status, body)
    body = body or ""
    local err_msg = json_field(body, "error") or ("HTTP " .. tostring(status))
    local hint    = json_field(body, "hint")

    if status == 401 then
        return {
            ok = false,
            kind = "unauthorized",
            message = err_msg,
            hint = hint or "Send X-Bridge-Key header matching Pi BRIDGE_API_KEY",
            http_status = status,
        }
    end
    if status == 503 then
        return {
            ok = false,
            kind = "meter_unavailable",
            message = err_msg,
            hint = hint or "Meter not connected — check USB",
            http_status = status,
        }
    end
    if status == 409 then
        return {
            ok = false,
            kind = "busy",
            message = err_msg,
            hint = hint or "Measurement already in progress",
            http_status = status,
        }
    end
    if status == 504 then
        return {
            ok = false,
            kind = "timeout",
            message = err_msg,
            hint = hint or "Meter did not respond in time",
            http_status = status,
        }
    end
    if status == 422 then
        return {
            ok = false,
            kind = "invalid_measurement",
            message = err_msg,
            hint = hint or "Sensor may be covered or aimed away from the "
                         .."light source — uncover/aim it and try again",
            http_status = status,
        }
    end
    return {
        ok = false,
        kind = "http",
        message = err_msg,
        hint = hint,
        http_status = status,
    }
end

function M.request(method, host, port, path, opts)
    opts = opts or {}
    local timeout_s = opts.timeout_s or M.TIMEOUT_STATUS
    local api_key   = opts.api_key

    local ok, socket = pcall(require, "socket")
    if not ok then
        return { ok = false, kind = "connection", message = "luasocket_unavailable" }
    end

    local tcp = socket.tcp()
    tcp:settimeout(timeout_s)

    local conn_ok, conn_err = tcp:connect(host, port)
    if not conn_ok then
        tcp:close()
        return {
            ok = false,
            kind = "connection",
            message = "connection_refused: " .. tostring(conn_err),
        }
    end

    local header_lines = {
        string.format("Host: %s", host),
        "Content-Length: 0",
    }
    if api_key and api_key ~= "" then
        header_lines[#header_lines + 1] = string.format("X-Bridge-Key: %s", api_key)
    end
    local req = string.format(
        "%s %s HTTP/1.0\r\n%s\r\n\r\n",
        method, path, table.concat(header_lines, "\r\n"))
    tcp:send(req)

    tcp:settimeout(timeout_s)
    -- Read until the peer closes the connection. Our requests are sent as
    -- HTTP/1.0 with no keep-alive, so the bridge (uvicorn) always closes
    -- after writing the response — "*a" is the correct/idiomatic pattern
    -- for that ("read everything until EOF", never errors, always returns
    -- what it got). The previous implementation looped on receive(4096)
    -- (an EXACT byte-count request) and only kept the first return value;
    -- since every response here is well under 4096 bytes, the peer closes
    -- before that many bytes arrive, so receive() returned (nil, "closed",
    -- partial-data) and the real bytes — sitting in the discarded third
    -- return value — were lost every single time. That produced an empty
    -- `full` string below, which failed to match the HTTP status line and
    -- was misreported as "invalid_http_response" even when the bridge
    -- answered correctly.
    local data, recv_err, partial = tcp:receive("*a")
    tcp:close()

    local full   = data or partial or ""
    local status = tonumber(full:match("HTTP/%d%.%d (%d+)"))
    local body   = full:match("\r\n\r\n(.-)$") or ""

    if not status then
        return { ok = false, kind = "connection", message = "invalid_http_response" }
    end
    return { ok = true, status = status, body = body }
end

function M.parse_measure_body(body)
    if not body or body == "" then
        return nil, { ok = false, kind = "malformed", message = "empty_response" }
    end
    -- cri/r9 use the same "%-?[%d%.]+" (allow leading minus) pattern as
    -- cct/duv, not "%d+". The C-7000 reports out-of-range sentinel values
    -- (e.g. cri=-200, r9=-200) when its sensor is covered or aimed away
    -- from any light source; a digits-only pattern silently failed to
    -- match those negative sentinels at all, which surfaced as a
    -- confusing "malformed_response" instead of the accurate
    -- "cri_out_of_range" / "r9_out_of_range" validation error produced
    -- below (the bridge server also bounds-checks this server-side —
    -- see C7000Bulk._parse()).
    local cct  = tonumber(body:match('"cct"%s*:%s*(%-?[%d%.]+)'))
    local duv  = tonumber(body:match('"duv"%s*:%s*(%-?[%d%.]+)'))
    local cri  = tonumber(body:match('"cri"%s*:%s*(%-?[%d%.]+)'))
    local r9   = tonumber(body:match('"r9"%s*:%s*(%-?[%d%.]+)'))
    local tlci = tonumber(body:match('"tlci"%s*:%s*(%-?[%d%.]+)'))
    if not cct or not duv or not cri or not r9 then
        return nil, { ok = false, kind = "malformed", message = "malformed_response" }
    end
    if cct < M.CCT_MIN or cct > M.CCT_MAX then
        return nil, { ok = false, kind = "validation", message = "cct_out_of_range" }
    end
    if duv < M.DUV_MIN or duv > M.DUV_MAX then
        return nil, { ok = false, kind = "validation", message = "duv_out_of_range" }
    end
    if cri < M.CRI_MIN or cri > M.CRI_MAX then
        return nil, { ok = false, kind = "validation", message = "cri_out_of_range" }
    end
    if r9 < M.CRI_MIN or r9 > M.CRI_MAX then
        return nil, { ok = false, kind = "validation", message = "r9_out_of_range" }
    end
    return { cct = cct, duv = duv, cri = cri, r9 = r9, tlci = tlci }, nil
end

function M.parse_status_body(body)
    if not body or body == "" then
        return nil
    end
    local auth_required = body:find('"auth_required"%s*:%s*true') ~= nil
    local last_error = json_field(body, "last_error")
    if last_error == "null" then last_error = nil end
    return {
        connected         = body:find('"connected"%s*:%s*true') ~= nil,
        device_configured = body:find('"device_configured"%s*:%s*true') ~= nil,
        protocol_captured = body:find('"protocol_captured"%s*:%s*true') ~= nil,
        trigger_discovered = body:find('"trigger_discovered"%s*:%s*true') ~= nil,
        meter             = body:match('"meter"%s*:%s*"([^"]+)"'),
        auth_required     = auth_required,
        last_error        = last_error,
    }
end

local function bridge_config(config)
    return {
        host    = config.bridge_ip,
        port    = config.bridge_port or 8765,
        api_key = config.bridge_api_key,
    }
end

local function route_request(config, method, path, timeout_s)
    if not config or not config.bridge_ip or config.bridge_ip == "" then
        return { ok = false, kind = "config", message = "no_bridge_configured" }
    end
    local bc = bridge_config(config)
    local resp = M.request(method, bc.host, bc.port, path, {
        timeout_s = timeout_s,
        api_key   = bc.api_key,
    })
    if not resp.ok then return resp end
    if resp.status ~= 200 then
        return M.classify_http(resp.status, resp.body)
    end
    return { ok = true, status = resp.status, body = resp.body }
end

function M.fetch_measurement(config)
    local resp = route_request(config, "POST", "/measure", M.TIMEOUT_MEASURE)
    if not resp.ok then return resp end
    local data, err = M.parse_measure_body(resp.body)
    if not data then return err end
    return { ok = true, data = data }
end

function M.check_status(config)
    local resp = route_request(config, "GET", "/status", M.TIMEOUT_STATUS)
    if not resp.ok then return resp end
    local data = M.parse_status_body(resp.body)
    if not data then
        return { ok = false, kind = "malformed", message = "malformed_status_response" }
    end
    return { ok = true, data = data }
end

function M.discover(config)
    return route_request(config, "GET", "/discover", M.TIMEOUT_DISCOVER)
end

function M.capture(config)
    return route_request(config, "POST", "/capture", M.TIMEOUT_CAPTURE)
end

function M.learn_trigger(config)
    return route_request(config, "POST", "/learn_trigger", M.TIMEOUT_LEARN_TRIGGER)
end

return M
