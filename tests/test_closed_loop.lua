local color_math = require("color_math")
local goals = require("goals")

local function cct_duv_to_xy(cct, duv)
    local x, y = color_math.cct_to_xy(cct)
    return color_math.apply_duv_correction(x, y, 0, duv)
end

local function xy_to_cct_duv(x, y)
    local n = (x - 0.3320) / (0.1858 - y)
    local cct = 437 * n ^ 3 + 3601 * n ^ 2 + 6861 * n + 5517
    local up, vp = color_math.xy_to_uvp(x, y)
    local lx, ly = color_math.cct_to_xy(cct)
    local lup, lvp = color_math.xy_to_uvp(lx, ly)
    local duv = (vp - lvp) / 1.5
    return cct, duv
end

local function simulate_plant(measured_x, measured_y, applied_x, applied_y, gain)
    local req_up, req_vp = color_math.xy_to_uvp(applied_x, applied_y)
    local prev_up, prev_vp = color_math.xy_to_uvp(measured_x, measured_y)
    local meas_up = prev_up + gain * (req_up - prev_up)
    local meas_vp = prev_vp + gain * (req_vp - prev_vp)
    return color_math.uvp_to_xy(meas_up, meas_vp)
end

local function run_plant_simulation(gain, max_attempts)
    local target = { cct = 5600, duv = 0.000 }
    local measured_x, measured_y = cct_duv_to_xy(5200, 0.012)
    local applied_x, applied_y = nil, nil
    local correction_opts = {}

    for attempt = 1, max_attempts do
        local meas_cct, meas_duv = xy_to_cct_duv(measured_x, measured_y)
        local measured = { cct = meas_cct, duv = meas_duv, cri = 90, r9 = 50 }
        if goals.goals_met(measured, target) then
            return true, attempt
        end

        if attempt >= max_attempts then
            break
        end

        local corr = color_math.get_correction(
            target.cct, target.duv, meas_cct, meas_duv,
            applied_x, applied_y, correction_opts)
        correction_opts = {
            prev_delta_cct = corr.delta_cct,
            prev_delta_duv = corr.delta_duv,
            prev_error_mag = corr.error_mag,
        }

        measured_x, measured_y = simulate_plant(
            measured_x, measured_y, corr.target_x, corr.target_y, gain)
        applied_x, applied_y = corr.target_x, corr.target_y
    end

    return false, max_attempts
end

return function(M)
    M.section("compute_closed_loop_gains – oscillation damping")
    do
        local gain_u, gain_v = color_math.compute_closed_loop_gains(100, -0.005, {
            prev_delta_cct = -80,
            prev_delta_duv = 0.004,
        })
        M.assert_near("oscillation halves u gain", gain_u, 0.5, 0.001)
        M.assert_near("oscillation halves v gain", gain_v, 0.425, 0.001)
    end

    M.section("get_correction – closed-loop moves toward target")
    do
        local corr1 = color_math.get_correction(5600, 0.0, 5200, 0.010, nil, nil)
        M.assert_true("open-loop delta_cct positive when too warm",
            corr1.delta_cct > 0)
        local corr2 = color_math.get_correction(
            5600, 0.0, 5300, 0.006, corr1.target_x, corr1.target_y, {
                prev_delta_cct = corr1.delta_cct,
                prev_delta_duv = corr1.delta_duv,
                prev_error_mag = corr1.error_mag,
            })
        M.assert_true("closed-loop reduces |delta_cct| vs open-loop repeat",
            math.abs(corr2.delta_cct) <= math.abs(corr1.delta_cct) + 50)
        M.assert_true("returns adaptive gain metadata",
            corr2.gain_u ~= nil and corr2.gain_v ~= nil and corr2.error_mag ~= nil)
    end

    M.section("should_use_setcolor_xy – unified control threshold")
    do
        local caps = { has_native_color_channels = true }
        local far = { delta_cct = 200, delta_duv = 0.010 }
        local close = { delta_cct = 40, delta_duv = 0.003 }
        M.assert_false("far error uses native only", color_math.should_use_setcolor_xy(far, caps))
        M.assert_true("close error uses SetColor xy", color_math.should_use_setcolor_xy(close, caps))
    end

    M.section("plant simulation – gain profiles")
    do
        local met_slow, n_slow = run_plant_simulation(0.35, 12)
        M.assert_true("under-responsive plant converges within hard cap", met_slow)
        M.assert_true("slow plant needs multiple attempts", n_slow >= 3)

        local met_fast, n_fast = run_plant_simulation(0.92, 12)
        M.assert_true("well-tuned plant converges quickly", met_fast)
        M.assert_true("fast plant converges in few attempts", n_fast <= 4)

        local met_osc, n_osc = run_plant_simulation(1.45, 12)
        M.assert_true("over-responsive plant still converges with adaptive gain", met_osc)
        M.assert_true("oscillating plant does not exhaust hard cap", n_osc < 12)
    end
end
