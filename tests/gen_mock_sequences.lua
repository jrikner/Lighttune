-- Generator: produces realistic, physically-grounded mock Sekonic measurement
-- sequences by literally driving the real goals.lua / color_math.lua
-- decision functions, the same way the desk's per-fixture calibration loop
-- does. Each attempt's applied correction is computed by the real
-- color_math.get_correction() from the previous attempt's simulated
-- measurement -- not hand-typed. Only the *fixture response* (how much of
-- a requested correction actually reaches the light output) is simulated,
-- via one number per profile: `gain`.
--
-- Model: on attempt 1 the fixture is measured in whatever state it's
-- already in (no correction applied yet). From attempt 2 onward, the real
-- get_correction() tells us how far it WANTS to move the commanded point
-- (in u'v', perceptually uniform space); the simulated fixture actually
-- moves `gain` fraction of that requested delta:
--     measured_uv(n) = measured_uv(n-1) + gain * requested_delta_uv(n)
-- gain = 1.0  -> fixture reproduces the correction exactly (converges in 1 step)
-- gain < 1.0  -> fixture under-responds (needs multiple nudges to converge)
-- gain > 1.0  -> fixture over-responds / overshoots (oscillates around target)
-- This makes error_n = (1 - gain)^(n-1) * error_1 for the cct/duv channel,
-- a standard discrete secant/fixed-point recurrence -- the same math a real
-- closed-loop control system exhibits with a miscalibrated plant gain.

package.path = "./lua/?.lua;./tests/?.lua"
local color_math = require("color_math")
local goals = require("goals")

local function cct_duv_to_xy(cct, duv)
    local x, y = color_math.cct_to_xy(cct)
    return color_math.apply_duv_correction(x, y, 0, duv)
end

-- Approximate xy -> CCT via McCamy's cubic approximation (host-side only).
local function xy_to_cct_duv(x, y)
    local n = (x - 0.3320) / (0.1858 - y)
    local cct = 437*n^3 + 3601*n^2 + 6861*n + 5517
    local up, vp = color_math.xy_to_uvp(x, y)
    local lx, ly = color_math.cct_to_xy(cct)
    local lup, lvp = color_math.xy_to_uvp(lx, ly)
    local duv = (vp - lvp) / 1.5
    return cct, duv
end

local TARGET = { cct = 3200, duv = 0.000,
                 cri = { mode = goals.GOAL_MIN, value = 90 },
                 r9  = { mode = goals.GOAL_MIN, value = 50 } }

local MAX_STAGNANT = 3
local MAX_ATTEMPTS_HARD = 12
local START_OFFSET_CCT = -350
local START_OFFSET_DUV = 0.015

local PROFILES = {
    {
        name = "steady_converge",
        fixture_id = 12,
        make_model = "Chauvet Professional / COLORado PXL Bar 16",
        hw_note = "Well-calibrated LED bar, but the color-mixing servo only "
               .. "closes about a third of the commanded correction per pass "
               .. "(mechanical backlash in the CMY flags) -- converges steadily "
               .. "over several attempts rather than in one shot.",
        gain = 0.32,
        cri0 = 82, cri_ceiling = 94,
        r90 = 38,  r9_ceiling = 56,
        quality_decay = 0.45,
    },
    {
        name = "quick_converge",
        fixture_id = 7,
        make_model = "Robe / T1 Profile",
        hw_note = "Precisely calibrated fixture; the xy servo tracks the "
               .. "commanded correction almost exactly, so it's really just "
               .. "R9 drive-current settling that gates how fast this one clears goal.",
        gain = 0.92,
        cri0 = 91, cri_ceiling = 95,
        r90 = 44,  r9_ceiling = 60,
        quality_decay = 0.30,
    },
    {
        name = "plateau_stuck",
        fixture_id = 19,
        make_model = "Generic / RGBW Wash (budget LED engine)",
        hw_note = "Improves for two correction passes, then the color-mixing "
               .. "flags hit their mechanical end-stop -- no further xy movement "
               .. "is physically possible. Its LED engine's CRI ceiling (89) also "
               .. "sits one point below the CRI-90 goal, so this fixture can "
               .. "never pass no matter how many attempts are given.",
        gain = 0.55,
        cri0 = 84, cri_ceiling = 89,   -- ceiling BELOW the 90 goal -- physically cannot pass
        r90 = 39,  r9_ceiling = 44,    -- ceiling BELOW the 50 goal
        quality_decay = 0.60,
        stuck_after = 2,
    },
    {
        name = "oscillate_settles",
        fixture_id = 24,
        make_model = "Generic / Moving Head Wash (loose color-mixing calibration)",
        hw_note = "Over-responsive color-mixing servo overshoots the requested "
               .. "correction every pass (classic under-damped response) -- "
               .. "swings past target on both sides before the swings decay "
               .. "enough to land inside tolerance.",
        gain = 1.45,
        cri0 = 85, cri_ceiling = 93,
        r90 = 40,  r9_ceiling = 55,
        quality_decay = 0.40,
    },
    {
        name = "oscillate_persistent",
        fixture_id = 31,
        make_model = "Generic / Ellipsoidal + Frame (color scroller retrofit)",
        hw_note = "Badly over-responsive servo (near-unstable gain) -- keeps "
               .. "swinging past target attempt after attempt; each swing is "
               .. "different enough from the last that it never reads as "
               .. "three-flat-attempts stagnation, but it also doesn't damp "
               .. "down fast enough to land inside tolerance before the hard "
               .. "attempt cap -- a fixture that genuinely needs a technician, "
               .. "not more auto-correction passes.",
        gain = 2.4,
        cri0 = 88, cri_ceiling = 93,
        r90 = 46,  r9_ceiling = 56,
        quality_decay = 0.50,
    },
    {
        name = "hard_cap_exhaust",
        fixture_id = 44,
        make_model = "Generic / Unstable RGB Matrix (uncalibrated gain)",
        hw_note = "Plant gain far above 1.0 even with adaptive damping — error "
               .. "sign keeps flipping but magnitude never shrinks enough to "
               .. "meet goals within MAX_ATTEMPTS_HARD.",
        gain = 5.0,
        cri0 = 86, cri_ceiling = 92,
        r90 = 41,  r9_ceiling = 54,
        quality_decay = 0.55,
    },
}

local out = {}
out[#out+1] = "-- AUTO-GENERATED by tests/gen_mock_sequences.lua -- do not hand-edit."
out[#out+1] = "-- Regenerate with: texlua tests/gen_mock_sequences.lua > tests/fixtures/mock_measurement_sequences.lua"
out[#out+1] = "-- Every attempt's applied correction is computed by the real"
out[#out+1] = "-- lua/color_math.get_correction(); every pass/fail/stagnation verdict"
out[#out+1] = "-- is computed by the real lua/goals.lua (error_score / has_improved /"
out[#out+1] = "-- goals_met). Only the simulated fixture response (how much of a"
out[#out+1] = "-- requested correction the fixture actually reproduces) is synthetic --"
out[#out+1] = "-- see tests/gen_mock_sequences.lua for the model. Deterministic: "
out[#out+1] = "-- re-running the generator reproduces byte-identical output."
out[#out+1] = ""
out[#out+1] = "return {"
out[#out+1] = string.format("  target = { cct=%d, duv=%.3f, cri_min=%d, r9_min=%d },",
                             TARGET.cct, TARGET.duv, TARGET.cri.value, TARGET.r9.value)
out[#out+1] = "  fixtures = {"

local summary = {}

for _, profile in ipairs(PROFILES) do
    out[#out+1] = "    {"
    out[#out+1] = string.format("      name = %q,", profile.name)
    out[#out+1] = string.format("      fixture_id = %d,", profile.fixture_id)
    out[#out+1] = string.format("      make_model = %q,", profile.make_model)
    out[#out+1] = string.format("      hw_note = %q,", profile.hw_note)
    out[#out+1] = "      attempts = {"

    local measured_x, measured_y = cct_duv_to_xy(TARGET.cct + START_OFFSET_CCT, START_OFFSET_DUV)
    local applied_x, applied_y = nil, nil
    local correction_opts = {}
    local stagnation = { best_score = nil, stagnant_count = 0 }
    local prev_score = nil
    local frozen = nil
    local met_at, stagnated_at, hard_cap_hit = nil, nil, false

    for attempt = 1, MAX_ATTEMPTS_HARD do
        local cct, duv

        if attempt > 1 then
            -- Real closed-loop correction, exactly as the desk computes it.
            local last_cct, last_duv = xy_to_cct_duv(measured_x, measured_y)
            local corr = color_math.get_correction(
                TARGET.cct, TARGET.duv, last_cct, last_duv,
                applied_x, applied_y, correction_opts)
            correction_opts = {
                prev_delta_cct = corr.delta_cct,
                prev_delta_duv = corr.delta_duv,
                prev_error_mag = corr.error_mag,
            }
            local new_applied_x, new_applied_y = corr.target_x, corr.target_y

            if profile.stuck_after and attempt > profile.stuck_after then
                -- Mechanical end-stop: no further movement possible.
                measured_x, measured_y = frozen.x, frozen.y
            else
                local req_up, req_vp = color_math.xy_to_uvp(new_applied_x, new_applied_y)
                local prev_up, prev_vp
                if applied_x then
                    prev_up, prev_vp = color_math.xy_to_uvp(applied_x, applied_y)
                else
                    prev_up, prev_vp = color_math.xy_to_uvp(measured_x, measured_y)
                end
                local delta_up = req_up - prev_up
                local delta_vp = req_vp - prev_vp

                local meas_up, meas_vp = color_math.xy_to_uvp(measured_x, measured_y)
                meas_up = meas_up + profile.gain * delta_up
                meas_vp = meas_vp + profile.gain * delta_vp
                measured_x, measured_y = color_math.uvp_to_xy(meas_up, meas_vp)
            end

            applied_x, applied_y = new_applied_x, new_applied_y
        end

        cct, duv = xy_to_cct_duv(measured_x, measured_y)
        cct = math.floor(cct + 0.5)
        duv = math.floor(duv * 10000 + 0.5) / 10000

        local cri = profile.cri_ceiling - (profile.cri_ceiling - profile.cri0) * (profile.quality_decay ^ (attempt - 1))
        local r9  = profile.r9_ceiling  - (profile.r9_ceiling  - profile.r90)  * (profile.quality_decay ^ (attempt - 1))
        cri = math.floor(cri + 0.5)
        r9  = math.floor(r9 + 0.5)

        if profile.stuck_after and attempt == profile.stuck_after then
            frozen = { x = measured_x, y = measured_y, cri = cri, r9 = r9 }
        end
        if profile.stuck_after and attempt > profile.stuck_after then
            cri, r9 = frozen.cri, frozen.r9
        end

        local measured = { cct = cct, duv = duv, cri = cri, r9 = r9 }
        local score = goals.error_score(measured, TARGET)
        local improved = goals.has_improved(score, prev_score)
        stagnation = goals.update_stagnation(stagnation, measured, score)
        local met = goals.goals_met(measured, TARGET)
        prev_score = score

        out[#out+1] = string.format(
            "        { attempt=%d, cct=%d, duv=%.4f, cri=%d, r9=%d, error_score=%.4f, improved=%s, goals_met=%s, stagnant_count=%d, reading_plateau=%s },",
            attempt, cct, duv, cri, r9, score, tostring(improved), tostring(met),
            stagnation.stagnant_count, tostring(stagnation.reading_plateau or false))

        if met and not met_at then met_at = attempt end
        if goals.is_stagnated(stagnation, MAX_STAGNANT) and not stagnated_at then
            stagnated_at = attempt
        end

        if met or goals.is_stagnated(stagnation, MAX_STAGNANT) then break end
        if attempt == MAX_ATTEMPTS_HARD then hard_cap_hit = true; break end
    end

    out[#out+1] = "      },"
    out[#out+1] = string.format("      expect_goals_met_at_attempt = %s,", met_at and tostring(met_at) or "nil")
    out[#out+1] = string.format("      expect_stagnation_at_attempt = %s,", stagnated_at and tostring(stagnated_at) or "nil")
    out[#out+1] = string.format("      expect_hard_cap_hit = %s,", tostring(hard_cap_hit))
    out[#out+1] = "    },"

    local outcome
    if met_at then outcome = string.format("goal met at attempt %d", met_at)
    elseif stagnated_at then outcome = string.format("auto-accepted (stagnant) at attempt %d", stagnated_at)
    else outcome = "hard attempt cap reached (12), never converged" end
    summary[#summary+1] = string.format("%-22s gain=%-5.2f -> %s", profile.name, profile.gain, outcome)
end

out[#out+1] = "  },"
out[#out+1] = "}"

print(table.concat(out, "\n"))
io.stderr:write("\n=== SUMMARY ===\n" .. table.concat(summary, "\n") .. "\n")
