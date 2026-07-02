-- config.lua — plugin paths and config.json loading (Phase 6)

local M = {}

function M.get_sep()
    local sep = "/"
    pcall(function() sep = GetPathSeparator() end)
    return sep
end

function M.normalize_plugin_dir(base, host_os, sep)
    if not base or base == "" then return nil end
    sep = sep or "/"
    return base .. sep .. "SekonicCalibrator"
end

function M.get_plugin_dir()
    local sep = M.get_sep()
    local base = nil
    pcall(function() base = GetPath(Enums.PathType.PluginLibrary) end)
    if base and base ~= "" then
        return M.normalize_plugin_dir(base, nil, sep)
    end
    local host = "Linux"
    pcall(function() host = HostOS() end)
    if host == "Windows" then
        sep = "\\"
        local appdata = (os.getenv and os.getenv("APPDATA"))
                     or "C:\\Users\\Default\\AppData\\Roaming"
        return appdata .. sep .. "MALightingTechnology" .. sep
            .. "gma3_library" .. sep .. "datapools" .. sep
            .. "plugins" .. sep .. "SekonicCalibrator"
    else
        local home = (os.getenv and os.getenv("HOME")) or "/root"
        return home .. sep .. "MALightingTechnology" .. sep
            .. "gma3_library" .. sep .. "datapools" .. sep
            .. "plugins" .. sep .. "SekonicCalibrator"
    end
end

function M.get_data_dir()
    local dir = M.get_plugin_dir()
    if not dir then return nil end
    return dir .. M.get_sep() .. "data"
end

function M.parse_config_content(content)
    if not content or content == "" then return nil end
    local username     = content:match('"github_username"%s*:%s*"([^"]+)"')
    local bridge_ip    = content:match('"bridge_ip"%s*:%s*"([^"]+)"')
    local bridge_port  = tonumber(content:match('"bridge_port"%s*:%s*(%d+)'))
    local bridge_api_key = content:match('"bridge_api_key"%s*:%s*"([^"]*)"')
    return {
        github_username  = username,
        bridge_ip        = bridge_ip,
        bridge_port      = bridge_port or 8765,
        bridge_api_key   = bridge_api_key,
    }
end

function M.load_config()
    local dir = M.get_plugin_dir()
    if not dir then return nil end
    local path = dir .. M.get_sep() .. "config.json"
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return M.parse_config_content(content)
end

return M
