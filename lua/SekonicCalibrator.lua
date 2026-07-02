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
        plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)[/\\][^/\\]+$")
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

    local function try_require_ui(name)
        local full = "ui." .. name
        local ok, mod = pcall(require, full)
        if ok and type(mod) == "table" then return mod end
        local chunk, err = loadfile(plugin_dir .. "/lua/ui/" .. name .. ".lua")
        if not chunk then error("module " .. full .. ": " .. tostring(err)) end
        mod = chunk()
        if type(mod) ~= "table" then error("module " .. full .. " must return a table") end
        package.loaded[full] = mod
        return mod
    end

    return {
        color_math     = try_require("color_math"),
        fixture_db     = try_require("fixture_db"),
        goals          = try_require("goals"),
        bridge_client  = try_require("bridge_client"),
        config         = try_require("config"),
        patch_api      = try_require("patch_api"),
        fixture_apply  = try_require("fixture_apply"),

        dialogs        = try_require_ui("dialogs"),
        session        = try_require_ui("session"),
        measurement    = try_require_ui("measurement"),
        assessment     = try_require_ui("assessment"),
        history        = try_require_ui("history"),
        bridge_ui      = try_require_ui("bridge"),

        calibration    = try_require("calibration"),
    }
end

local domain = load_domain_modules()
local config_mod     = domain.config
local ui_history     = domain.history
local ui_bridge      = domain.bridge_ui
local calibration    = domain.calibration

local function main(display, ...)
    local ok, err = pcall(function()
        local config = config_mod.load_config()

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

        local data_dir = config_mod.get_data_dir()
        local sep = config_mod.get_sep()

        if menu==2 then
            ui_history.show_fixture_history(display, data_dir)
            return
        end

        if menu==3 then
            ui_bridge.show_bridge_status(display, config)
            return
        end

        calibration.run(display, {
            config   = config,
            data_dir = data_dir,
            sep      = sep,
        })
    end)

    if not ok then
        MessageBox({ title="Unexpected Error",
            message="An unexpected error occurred:\n\n"..tostring(err)
                  .."\n\nPlease report this to the Lighttune project.",
            display_handle=display, buttons={"OK"} })
    end
end

return main
