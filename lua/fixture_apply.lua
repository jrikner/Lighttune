-- fixture_apply.lua — SetColor apply helpers (Phase 6 CAL-04)

local color_math = require("color_math")

local M = {}

function M.select_group(group)
    local ok,err=pcall(function() Cmd('Group "'..tostring(group)..'"') end)
    if not ok then
        local ok2,err2=pcall(function() Cmd("Group "..tostring(group)) end)
        if not ok2 then return false,tostring(err2) end
    end
    return true,nil
end

function M.apply_color_xyY(x,y)
    local ok,err=pcall(function() SetColor("xyY",x,y,1.0,1.0,1.0,false) end)
    if not ok then return false,tostring(err) end
    return true,nil
end

function M.apply_color_hsb(x,y)
    local r,g,b=color_math.xy_to_rgb(x,y); local h,s,_=color_math.rgb_to_hsb(r,g,b)
    local ok,err=pcall(function() SetColor("HSB",h,s,1.0,1.0,1.0,false) end)
    if not ok then return false,tostring(err) end
    return true,nil
end

function M.calibrate_group(group,x,y)
    local sel_ok,sel_err=M.select_group(group)
    if not sel_ok then return {success=false,method="none",error_msg=sel_err} end
    local xy_ok,xy_err=M.apply_color_xyY(x,y)
    if xy_ok then return {success=true,method="xyY (precision)",error_msg=nil} end
    local hsb_ok,hsb_err=M.apply_color_hsb(x,y)
    if hsb_ok then return {success=true,method="HSB (approx)",error_msg=nil} end
    return {success=false,method="none",
        error_msg=string.format("xyY: %s | HSB: %s",xy_err,hsb_err)}
end

return M
