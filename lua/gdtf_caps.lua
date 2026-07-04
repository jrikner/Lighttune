-- gdtf_caps.lua — read colour capabilities from MA3-parsed GDTF (FixtureType API).
-- GrandMA3 has already parsed the GDTF; we query DMXModes, attributes, and
-- physical ranges rather than unzipping GDTF files (not available in plugin Lua).

local M = {}

function M.new_caps()
    return {
        gdtf_source            = false,
        source                 = nil,
        has_tint               = false,
        has_ctb                = false,
        has_cto                = false,
        has_ctc                = false,
        has_rgb                = false,
        has_color_wheel        = false,
        has_color_wheel_filters = false,
        tint_attr              = nil,
        cto_attr               = nil,
        ctb_attr               = nil,
        ctc_attr               = nil,
        color_wheel_attr       = nil,
        color_wheel_slots      = {},
        tint_neutral           = 50,
        tint_min               = 0,
        tint_max               = 100,
        ctc_kelvin_min         = nil,
        ctc_kelvin_max         = nil,
        cto_kelvin_min         = nil,
        cto_kelvin_max         = nil,
        ctb_kelvin_min         = nil,
        ctb_kelvin_max         = nil,
        gdtf_cri               = nil,
        gdtf_cct               = nil,
        gdtf_tlci              = nil,
        gdtf_mode              = nil,
        gdtf_attrs             = {},
    }
end

function M.has_correctable_color(caps)
    if not caps then return false end
    return caps.has_tint or caps.has_cto or caps.has_ctb or caps.has_ctc or caps.has_rgb
        or caps.has_color_wheel or caps.has_color_wheel_filters
end

function M.has_native_color_channels(caps)
    if not caps then return false end
    return caps.has_tint or caps.has_cto or caps.has_ctb or caps.has_ctc
        or (caps.has_color_wheel and caps.color_wheel_attr)
end

local function num(v)
    if v == nil then return nil end
    return tonumber(v)
end

local function is_color_temp_unit(unit)
    unit = tostring(unit or ""):lower()
    return unit:find("colortemperature") or unit:find("colortemp") or unit == "k"
        or unit:find("kelvin")
end

local function merge_kelvin_range(caps, key_min, key_max, pf, pt)
    pf, pt = num(pf), num(pt)
    if not pf or not pt then return end
    if pf > 8000 and pt < 8000 then pf, pt = pt, pf end
    if pf < 1000 or pt > 25000 then return end
    local lo, hi = math.min(pf, pt), math.max(pf, pt)
    if not caps[key_min] or lo < caps[key_min] then caps[key_min] = lo end
    if not caps[key_max] or hi > caps[key_max] then caps[key_max] = hi end
end

local function track_attr(caps, attr)
    if not attr or attr == "" then return end
    caps.gdtf_attrs[attr] = true
end

local POSITION_ATTRS = {
    Pan = true, Tilt = true, PanTilt = true,
    XYZ_X = true, XYZ_Y = true, XYZ_Z = true,
    X = true, Y = true, Z = true,
    Rot_X = true, Rot_Y = true, Rot_Z = true,
}

function M.is_position_attribute(attr)
    if not attr or attr == "" then return false end
    if POSITION_ATTRS[attr] then return true end
    local lower = tostring(attr):lower()
    if lower:find("^pan") or lower:find("^tilt") or lower:find("^xyz") then return true end
    if lower:find("position") then return true end
    return false
end

function M.register_attribute(caps, attr, lc)
    if not caps or not attr or attr == "" then return end
    if M.is_position_attribute(attr) then return end
    track_attr(caps, attr)

    if attr == "Tint" then
        caps.has_tint = true
        caps.tint_attr = caps.tint_attr or attr
    elseif attr == "CTC" or attr == "ColorTemperature" or attr == "ColorTemperatureControl" then
        caps.has_ctc = true
        caps.ctc_attr = caps.ctc_attr or attr
    elseif attr == "CTO" then
        caps.has_cto = true
        caps.cto_attr = caps.cto_attr or attr
    elseif attr == "CTB" then
        caps.has_ctb = true
        caps.ctb_attr = caps.ctb_attr or attr
    elseif attr:find("^ColorAdd_") or attr:find("^ColorSub_") or attr:find("^ColorRGB") then
        caps.has_rgb = true
    elseif attr == "HSB_Hue" or attr == "HSB_Saturation" or attr == "CIE_X" or attr == "CIE_Y" then
        caps.has_rgb = true
    elseif attr == "ColorWheel" or attr:find("[Cc]olor[Ww]heel") then
        caps.has_color_wheel = true
        caps.has_color_wheel_filters = true
        caps.color_wheel_attr = caps.color_wheel_attr or attr
    end

    if not lc then return end
    local cfs = lc.ChannelFunctions
    if not cfs then return end
    local cf_count = 0
    pcall(function() cf_count = cfs:Count() end)

    for k = 0, math.max(cf_count - 1, 127) do
        local cf = cfs:Child(k)
        if not cf then break end
        local nm = tostring(cf.Name or cf.name or "")
        if caps.color_wheel_attr == attr and nm ~= "" and nm ~= "No Function" then
            caps.color_wheel_slots[#caps.color_wheel_slots + 1] = nm
        end

        local pf = cf.PhysicalFrom or cf.physicalfrom or cf.PhysicalFromValue
        local pt = cf.PhysicalTo or cf.physicalto or cf.PhysicalToValue
        local unit = cf.PhysicalUnit or cf.physicalunit or cf.Attribute or attr

        if attr == "Tint" or attr:find("Tint") then
            local dpf = num(cf.DmxValue or cf.dmxvalue or cf.PhysicalFrom)
            if dpf and dpf >= 40 and dpf <= 60 then
                caps.tint_neutral = dpf
            end
        end

        if is_color_temp_unit(unit) or attr == "CTC" or attr == "CTO" or attr == "CTB"
            or attr == "ColorTemperature" then
            local range_key_min, range_key_max
            if attr == "CTC" or attr == "ColorTemperature" or attr == "ColorTemperatureControl" then
                range_key_min, range_key_max = "ctc_kelvin_min", "ctc_kelvin_max"
            elseif attr == "CTO" then
                range_key_min, range_key_max = "cto_kelvin_min", "cto_kelvin_max"
            else
                range_key_min, range_key_max = "ctb_kelvin_min", "ctb_kelvin_max"
            end
            merge_kelvin_range(caps, range_key_min, range_key_max, pf, pt)
        end
    end
end

local function read_fixture_type_meta(caps, ft)
    if not caps or not ft then return false end
    local found = false

    pcall(function()
        local cri = num(ft.CRI or ft.Cri or ft.ColorRenderingIndex)
        if cri then caps.gdtf_cri = cri; found = true end
    end)
    pcall(function()
        local tlci = num(ft.TLCI or ft.Tlci)
        if tlci then caps.gdtf_tlci = tlci; found = true end
    end)
    pcall(function()
        local cct = num(ft.NominalColorTemperature or ft.ColorTemperature
            or ft.RefPhysicalColorTemperature or ft.refphysicalcolortemperature)
        if cct then caps.gdtf_cct = cct; found = true end
    end)

    return found
end

local function scan_dmx_mode(caps, mode)
    if not caps or not mode then return false end
    local found = false
    pcall(function()
        local name = mode.Name or mode.name
        if name then caps.gdtf_mode = tostring(name); found = true end
    end)

    local dch = mode.DMXChannels
    if not dch then return found end
    local ch_count = 0
    pcall(function() ch_count = dch:Count() end)

    for i = 0, math.max(ch_count - 1, 255) do
        local ch = dch:Child(i)
        if not ch then break end
        local lcs = ch.LogicalChannels
        if lcs then
            local lc_count = 0
            pcall(function() lc_count = lcs:Count() end)
            for j = 0, math.max(lc_count - 1, 31) do
                local lc = lcs:Child(j)
                if not lc then break end
                local attr = tostring(lc.Attribute or lc.name or "")
                if attr ~= "" then
                    found = true
                    M.register_attribute(caps, attr, lc)
                end
            end
        end
    end
    return found
end

local function resolve_dmx_mode(ft, fixture)
    local modes = ft and (ft.DMXModes or ft.dmxmodes)
    if not modes then return nil end

    if fixture then
        local patched = nil
        pcall(function()
            patched = fixture.DMXMode or fixture.dmxmode or fixture.Mode or fixture.mode
        end)
        if patched then return patched end
    end

    local mode = nil
    pcall(function() mode = modes.Default end)
    if mode then return mode end
    pcall(function() mode = modes:Child(0) end)
    return mode
end

-- Primary entry: read caps from a FixtureType handle (+ optional patched fixture for mode).
function M.read_from_fixture_type(ft, fixture)
    local caps = M.new_caps()
    if not ft then return M.finalize_caps(caps, false) end

    local found = read_fixture_type_meta(caps, ft)
    local mode = resolve_dmx_mode(ft, fixture)
    if mode and scan_dmx_mode(caps, mode) then
        found = true
    end

    -- Union attributes from every DMX mode when the patched/default mode is sparse.
    if not M.has_native_color_channels(caps) then
        local modes = ft.DMXModes or ft.dmxmodes
        if modes then
            local mode_count = 0
            pcall(function() mode_count = modes:Count() end)
            for i = 0, math.max(mode_count - 1, 15) do
                local m = modes:Child(i)
                if m and m ~= mode and scan_dmx_mode(caps, m) then
                    found = true
                end
            end
        end
    end

    if found then
        caps.gdtf_source = true
        caps.source = "gdtf"
    end
    return M.finalize_caps(caps, found)
end

-- Last resort when Patch/GDTF is unreachable — SetColor only.
function M.finalize_caps(caps, gdtf_reachable)
    caps = caps or M.new_caps()
    if caps.gdtf_source or gdtf_reachable then
        caps.source = caps.source or "gdtf"
        return caps
    end
    if not M.has_correctable_color(caps) then
        caps.has_rgb = true
        caps.source = "fallback_setcolor"
    end
    return caps
end

function M.clamp_ctc_kelvin(caps, kelvin)
    kelvin = num(kelvin) or 5600
    local lo = caps and (caps.ctc_kelvin_min or caps.cto_kelvin_min) or 2700
    local hi = caps and (caps.ctc_kelvin_max or caps.cto_kelvin_max) or 10000
    if lo and hi and lo > hi then lo, hi = hi, lo end
    lo = lo or 2700
    hi = hi or 10000
    return math.max(lo, math.min(hi, kelvin))
end

function M.summary(caps)
    if not caps then return "no caps" end
    if not caps.gdtf_source then return "GDTF unavailable (SetColor fallback)" end
    local parts = {}
    if caps.has_ctc then parts[#parts + 1] = (caps.ctc_attr or "CTC") .. " K" end
    if caps.has_cto then parts[#parts + 1] = caps.cto_attr or "CTO" end
    if caps.has_ctb then parts[#parts + 1] = caps.ctb_attr or "CTB" end
    if caps.has_tint then parts[#parts + 1] = caps.tint_attr or "Tint" end
    if caps.has_rgb then parts[#parts + 1] = "RGB/xy" end
    if caps.has_color_wheel then parts[#parts + 1] = caps.color_wheel_attr or "ColorWheel" end
    local attrs = #parts > 0 and table.concat(parts, ", ") or "metadata only"
    local cct = caps.gdtf_cct and string.format(" nominal %dK", caps.gdtf_cct) or ""
    return "GDTF: " .. attrs .. cct
end

return M
