-- patch_api.lua — MA3 patch read helpers (Phase 6 UX-01/02)

local M = {}

function M.get_fixture_from_patch(group_name)
    local make, model = nil, nil
    pcall(function()
        local dp = DataPool(); if not dp then return end
        local groups = dp.Groups; if not groups then return end
        local grp = nil
        local num = tonumber(group_name)
        if num then grp = groups:Child(num-1) end
        if not grp then
            for i=0, groups:Count()-1 do
                local g = groups:Child(i)
                if g and g.Name==group_name then grp=g; break end
            end
        end
        if not grp then return end
        local members = grp.Members
        if not members or members:Count()==0 then return end
        local fixture = members:Child(0); if not fixture then return end
        local ft = fixture.FixtureType; if not ft then return end
        local m = ft.Manufacturer; local n = ft.Long or ft.Name
        if m and m~="" then make=m end
        if n and n~="" then model=n end
    end)
    return make, model
end

function M.read_capabilities_from_patch(group_name)
    if not group_name then return nil end
    local caps = {
        has_tint               = false,
        has_ctb                = false,
        has_cto                = false,
        has_rgb                = false,
        has_color_wheel        = false,
        has_color_wheel_filters = false,
        gdtf_cri               = nil,
        gdtf_cct               = nil,
    }
    local found_any = false

    pcall(function()
        local dp = DataPool(); if not dp then return end
        local groups = dp.Groups; if not groups then return end
        local grp = nil
        local num = tonumber(group_name)
        if num then grp = groups:Child(num-1) end
        if not grp then
            for i = 0, groups:Count()-1 do
                local g = groups:Child(i)
                if g and g.Name == group_name then grp = g; break end
            end
        end
        if not grp then return end

        local members = grp.Members
        if not members or members:Count() == 0 then return end
        local fixture = members:Child(0); if not fixture then return end
        local ft = fixture.FixtureType;   if not ft      then return end

        pcall(function()
            local cri = tonumber(ft.CRI or ft.Cri)
            if cri then caps.gdtf_cri = cri; found_any = true end
        end)
        pcall(function()
            local cct = tonumber(ft.NominalColorTemperature or ft.ColorTemperature)
            if cct then caps.gdtf_cct = cct; found_any = true end
        end)

        local modes = ft.DMXModes; if not modes then return end
        local mode  = nil
        pcall(function() mode = modes.Default end)
        if not mode then pcall(function() mode = modes:Child(0) end) end
        if not mode then return end

        local dch = mode.DMXChannels; if not dch then return end
        local ch_count = 0
        pcall(function() ch_count = dch:Count() end)

        for i = 0, math.max(ch_count - 1, 99) do
            local ch = dch:Child(i); if not ch then break end
            pcall(function()
                local lcs = ch.LogicalChannels; if not lcs then return end
                local lc  = lcs:Child(0);        if not lc  then return end
                local attr = tostring(lc.Attribute or lc.name or "")
                if attr == "" then return end
                found_any = true
                if attr == "Tint"   then caps.has_tint = true end
                if attr == "CTO"    then caps.has_cto  = true end
                if attr == "CTB"    then caps.has_ctb  = true end
                if attr:find("^ColorAdd_") or attr:find("^ColorSub_") then
                    caps.has_rgb = true
                end
                if attr == "ColorWheel" or attr:find("[Cc]olor[Ww]heel") then
                    caps.has_color_wheel        = true
                    caps.has_color_wheel_filters = true
                end
            end)
        end
    end)

    if not found_any then return nil end
    return caps
end

return M
