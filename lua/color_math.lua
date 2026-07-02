-- color_math.lua — Section 2 pure color math (extracted from SekonicCalibrator.lua)
-- Host-testable; no MA3 API. Return-M contract for require/dofile loader.

local M = {}

M.CCT_MIN = 1667
M.CCT_MAX = 25000
M.DUV_MIN = -0.02
M.DUV_MAX =  0.02

M.GEL_STEPS = {
    { threshold = 0.016, amount = "Full" },
    { threshold = 0.010, amount = "1/2"  },
    { threshold = 0.006, amount = "1/4"  },
    { threshold = 0.003, amount = "1/8"  },
}

local DUV_QUALITY = {
    excellent = 0.003,
    good = 0.006,
    acceptable = 0.010,
}

function M.cct_to_xy(T)
    T = math.max(M.CCT_MIN, math.min(M.CCT_MAX, T))
    local x, y
    if T <= 4000 then
        x = (-0.2661239e9 / T^3) + (-0.2343580e6 / T^2) + (0.8776956e3 / T) + 0.179910
        y = (-1.1063814 * x^3) + (-1.34811020 * x^2) + (2.18555832 * x) - 0.20219683
    else
        x = (-3.0258469e9 / T^3) + (2.1070379e6 / T^2) + (0.2226347e3 / T) + 0.240390
        y = (3.0817580 * x^3) + (-5.87338670 * x^2) + (3.75112997 * x) - 0.37001483
    end
    return x, y
end

function M.xy_to_uvp(x, y)
    local denom = -2 * x + 12 * y + 3
    if denom == 0 then return 0, 0 end
    return 4 * x / denom, 9 * y / denom
end

function M.uvp_to_xy(up, vp)
    local denom = 6 * up - 16 * vp + 12
    if denom == 0 then return 0, 0 end
    return 9 * up / denom, 4 * vp / denom
end

function M.apply_duv_correction(x, y, measured_duv, target_duv)
    local up, vp = M.xy_to_uvp(x, y)
    vp = vp + (target_duv - measured_duv) * 1.5
    return M.uvp_to_xy(up, vp)
end

function M.get_correction(tgt_cct, tgt_duv, meas_cct, meas_duv)
    local tx, ty = M.cct_to_xy(tgt_cct)
    tx, ty = M.apply_duv_correction(tx, ty, 0, tgt_duv)
    return {
        target_x  = tx,
        target_y  = ty,
        delta_cct = tgt_cct - meas_cct,
        delta_duv = tgt_duv - meas_duv,
    }
end

function M.xy_to_rgb(x, y)
    if y == 0 then y = 0.0001 end
    local X = x / y
    local Y = 1.0
    local Z = (1 - x - y) / y
    local r_lin =  3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
    local g_lin = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
    local b_lin =  0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
    r_lin = math.max(0, r_lin); g_lin = math.max(0, g_lin); b_lin = math.max(0, b_lin)
    local max_c = math.max(r_lin, g_lin, b_lin)
    if max_c > 0 then r_lin = r_lin/max_c; g_lin = g_lin/max_c; b_lin = b_lin/max_c end
    return r_lin^(1/2.2), g_lin^(1/2.2), b_lin^(1/2.2)
end

function M.rgb_to_hsb(r, g, b)
    local max_c = math.max(r, g, b)
    local min_c = math.min(r, g, b)
    local delta = max_c - min_c
    local bri = max_c
    local s = (max_c == 0) and 0 or (delta / max_c)
    local h
    if delta == 0 then h = 0
    elseif max_c == r then h = 60 * (((g-b)/delta) % 6)
    elseif max_c == g then h = 60 * (((b-r)/delta) + 2)
    else                   h = 60 * (((r-g)/delta) + 4)
    end
    if h < 0 then h = h + 360 end
    return h, s, bri
end

function M.rate_quality(value, thresholds)
    if value >= thresholds.excellent  then return "Excellent"
    elseif value >= thresholds.good   then return "Good"
    elseif value >= thresholds.acceptable then return "Acceptable"
    else return "Poor" end
end

function M.rate_duv(duv)
    local a = math.abs(duv)
    if a <= DUV_QUALITY.excellent    then return "Excellent"
    elseif a <= DUV_QUALITY.good     then return "Good"
    elseif a <= DUV_QUALITY.acceptable then return "Acceptable"
    else return "Poor" end
end

function M.gel_hint(duv)
    local abs_duv = math.abs(duv)
    local amount = nil
    for _, step in ipairs(M.GEL_STEPS) do
        if abs_duv > step.threshold then amount = step.amount; break end
    end
    if not amount then return nil end
    if duv > 0 then
        return string.format("%s Minus Green  (Duv %+.4f, green shift)", amount, duv)
    else
        return string.format("%s Plus Green   (Duv %+.4f, magenta shift)", amount, duv)
    end
end

return M
