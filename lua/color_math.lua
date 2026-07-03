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

-- get_correction: compute the next xy to send to the fixture.
--
-- tgt_cct/tgt_duv   – the calibration target.
-- meas_cct/meas_duv – the values the Sekonic just measured on the fixture
--                      (i.e. the result of whatever was applied last time,
--                      or of the fixture's default/cold state on attempt 1).
-- prev_x/prev_y      – the xy that was actually SENT to the fixture to
--                      produce that measurement (nil on the very first
--                      attempt, when nothing has been applied yet).
--
-- Closed-loop (prev_x/prev_y given): most color-mixing fixtures do not
-- reproduce a commanded xy exactly — LED binning, dimmer-curve interaction,
-- gel/diffusion absorption, and the meter's own calibration all introduce
-- a fixture-specific offset between "what we told it" and "what it put
-- out". Recomputing the open-loop target from tgt_cct/tgt_duv every
-- attempt (the original behaviour) ignores that offset completely, so it
-- converges only by luck. Instead this applies a proportional/secant-style
-- update in CIE 1976 u'v' space (perceptually uniform, so a fixed-size
-- step means a fixed-size visual correction regardless of where in the
-- gamut we are): the correction is added not to the target, but to the
-- point we actually sent last time —
--     next_applied = prev_applied + (target - measured)
-- — which directly cancels out the fixture's measured response error.
-- With gain=1 this is the standard secant-method update for a
-- (locally-)linear system and typically converges in 2-3 iterations for
-- real fixtures; a fixture with a strongly nonlinear response may need a
-- couple more, but each step still moves monotonically toward target
-- instead of repeating the same open-loop guess.
--
-- Open-loop (prev_x/prev_y nil): the first attempt has no fixture response
-- yet to learn from, so this returns the direct cct/duv → xy conversion,
-- same as the original behaviour.
function M.get_correction(tgt_cct, tgt_duv, meas_cct, meas_duv, prev_x, prev_y)
    local tx, ty = M.cct_to_xy(tgt_cct)
    tx, ty = M.apply_duv_correction(tx, ty, 0, tgt_duv)

    local target_x, target_y = tx, ty

    if prev_x and prev_y then
        local mx, my = M.cct_to_xy(meas_cct)
        mx, my = M.apply_duv_correction(mx, my, 0, meas_duv)

        local meas_up, meas_vp = M.xy_to_uvp(mx, my)
        local tgt_up,  tgt_vp  = M.xy_to_uvp(tx, ty)
        local prev_up, prev_vp = M.xy_to_uvp(prev_x, prev_y)

        local GAIN = 1.0
        local next_up = prev_up + GAIN * (tgt_up - meas_up)
        local next_vp = prev_vp + GAIN * (tgt_vp - meas_vp)

        target_x, target_y = M.uvp_to_xy(next_up, next_vp)
    end

    return {
        target_x  = target_x,
        target_y  = target_y,
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

function M.clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- Match a ColorWheel slot name to a correction need (fixture-specific names).
function M.pick_wheel_slot(slots, need)
    if not slots or #slots == 0 then return nil end
    local patterns = {
        minus_green = { "minus green", "minusgreen", "minus g", "magenta" },
        plus_green  = { "plus green", "plusgreen", "plus g" },
        cto         = { "full cto", "1/2 cto", "1/4 cto", "1/8 cto", "cto", "3200", "warm" },
        ctb         = { "full ctb", "1/2 ctb", "1/4 ctb", "1/8 ctb", "ctb", "5600", "7000", "cool" },
    }
    local pats = patterns[need]
    if not pats then return nil end
    for _, slot in ipairs(slots) do
        local s = tostring(slot):lower()
        for _, pat in ipairs(pats) do
            if s:find(pat, 1, true) then return slot end
        end
    end
    return nil
end

-- Closed-loop adjustments for Tint / CTO / CTB / ColorWheel (secant-style bumps).
-- SetColor xy still handles RGB-mix fine tuning; these channels coarse-correct first.
local CCT_CHANNEL_GAIN   = 0.04   -- CTO/CTB % per Kelvin of error
local DUV_TINT_GAIN      = 350    -- Tint units per Duv (fixture-dependent)
local CCT_USE_THRESHOLD  = 60     -- Kelvin
local DUV_USE_THRESHOLD  = 0.002

function M.compute_channel_adjustments(correction, caps, prev)
    prev = prev or {}
    local out = {
        tint             = prev.tint or 0,
        cto              = prev.cto or 0,
        ctb              = prev.ctb or 0,
        color_wheel_slot = prev.color_wheel_slot,
        tint_changed     = false,
        cto_changed      = false,
        ctb_changed      = false,
        wheel_changed    = false,
    }
    if not correction or not caps then return out end

    local dk = correction.delta_cct or 0
    local dd = correction.delta_duv or 0
    local slots = caps.color_wheel_slots

    if math.abs(dk) >= CCT_USE_THRESHOLD then
        if dk > 0 and caps.has_cto then
            out.cto = M.clamp((prev.cto or 0) + dk * CCT_CHANNEL_GAIN, 0, 100)
            out.cto_changed = true
        elseif dk < 0 and caps.has_ctb then
            out.ctb = M.clamp((prev.ctb or 0) + (-dk) * CCT_CHANNEL_GAIN, 0, 100)
            out.ctb_changed = true
        elseif slots and caps.color_wheel_attr then
            local slot = dk > 0 and M.pick_wheel_slot(slots, "cto")
                or M.pick_wheel_slot(slots, "ctb")
            if slot then
                out.color_wheel_slot = slot
                out.wheel_changed = true
            end
        end
    end

    if math.abs(dd) >= DUV_USE_THRESHOLD then
        if caps.has_tint then
            out.tint = M.clamp((prev.tint or 0) - dd * DUV_TINT_GAIN, -100, 100)
            out.tint_changed = true
        elseif slots and caps.color_wheel_attr then
            local slot = dd > 0 and M.pick_wheel_slot(slots, "minus_green")
                or M.pick_wheel_slot(slots, "plus_green")
            if slot then
                out.color_wheel_slot = slot
                out.wheel_changed = true
            end
        end
    end

    return out
end

return M
