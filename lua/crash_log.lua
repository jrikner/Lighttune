-- crash_log.lua — append-only session/crash log for GrandMA3 plugin debugging.
-- Writes to <plugin>/data/crash_log.jsonl (io.open works; io.popen does not).

local M = {}

local LOG_NAME = "crash_log.jsonl"
local MAX_LINES = 400

local data_dir_fn = nil
local sep_fn = nil
local context = {}

local function sep()
    return (sep_fn and sep_fn()) or "/"
end

local function log_path()
    if not data_dir_fn then return nil end
    local dir = data_dir_fn()
    if not dir then return nil end
    return dir .. sep() .. LOG_NAME
end

local function json_escape(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\r", "\\r")
    s = s:gsub("\n", "\\n")
    return s
end

local function encode_ctx(extra)
    local parts = {}
    for k, v in pairs(context) do
        parts[#parts + 1] = string.format('"%s":"%s"', json_escape(k), json_escape(v))
    end
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            parts[#parts + 1] = string.format('"%s":"%s"', json_escape(k), json_escape(v))
        end
    end
    if #parts == 0 then return "{}" end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function trim_log(path)
    local rf = io.open(path, "r")
    if not rf then return end
    local lines = {}
    for line in rf:lines() do
        if line ~= "" then lines[#lines + 1] = line end
    end
    rf:close()
    if #lines <= MAX_LINES then return end
    local wf = io.open(path, "w")
    if not wf then return end
    for i = #lines - MAX_LINES + 1, #lines do
        wf:write(lines[i], "\n")
    end
    wf:close()
end

function M.init(get_data_dir, get_sep)
    data_dir_fn = get_data_dir
    sep_fn = get_sep
end

function M.path()
    return log_path()
end

function M.set_context(fields)
    if type(fields) ~= "table" then return end
    for k, v in pairs(fields) do
        if v == nil then
            context[k] = nil
        else
            context[k] = tostring(v)
        end
    end
end

function M.clear_context()
    context = {}
end

function M.trace(level, event, extra)
    local path = log_path()
    if not path then return false end

    local ok = pcall(function()
        local line = string.format(
            '{"ts":"%s","level":"%s","event":"%s","ctx":%s}',
            os.date("%Y-%m-%dT%H:%M:%S"),
            json_escape(level or "info"),
            json_escape(event or "trace"),
            encode_ctx(extra))
        local wf = io.open(path, "a")
        if not wf then return end
        wf:write(line, "\n")
        wf:close()
    end)
    return ok
end

function M.log_exception(err, extra)
    local message = tostring(err or "unknown error")
    local traceback = nil
    pcall(function()
        traceback = debug.traceback(message, 2)
    end)

    local path = log_path()
    pcall(function()
        if not path then return end
        trim_log(path)
        local line = string.format(
            '{"ts":"%s","level":"error","event":"exception","message":"%s","traceback":"%s","ctx":%s}',
            os.date("%Y-%m-%dT%H:%M:%S"),
            json_escape(message),
            json_escape(traceback or message),
            encode_ctx(extra))
        local wf = io.open(path, "a")
        if not wf then return end
        wf:write(line, "\n")
        wf:close()
    end)

    return path
end

function M.read_tail(max_lines)
    max_lines = max_lines or 20
    local path = log_path()
    if not path then return nil, "log path unavailable" end
    local rf = io.open(path, "r")
    if not rf then return nil, "no crash log yet" end
    local lines = {}
    for line in rf:lines() do
        if line ~= "" then lines[#lines + 1] = line end
    end
    rf:close()
    if #lines == 0 then return "", nil end
    local start = math.max(1, #lines - max_lines + 1)
    local out = {}
    for i = start, #lines do out[#out + 1] = lines[i] end
    return table.concat(out, "\n"), nil
end

function M.format_for_display(max_lines)
    local raw, err = M.read_tail(max_lines)
    if err then return err end
    if not raw or raw == "" then return "Crash log is empty." end

    local lines = {}
    for entry in raw:gmatch("[^\n]+") do
        local ts = entry:match('"ts":"([^"]+)"') or "?"
        local level = entry:match('"level":"([^"]+)"') or "?"
        local event = entry:match('"event":"([^"]+)"') or "?"
        local message = entry:match('"message":"([^"]+)"')
        local traceback = entry:match('"traceback":"([^"]+)"')
        local summary = message or event
        if traceback and traceback ~= "" and traceback ~= summary then
            summary = summary .. "\n  " .. traceback:gsub("\\n", "\n  ")
        end
        lines[#lines + 1] = string.format("[%s] %s — %s", ts, level:upper(), summary)
    end
    return table.concat(lines, "\n\n")
end

return M
