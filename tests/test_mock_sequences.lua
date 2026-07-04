-- Verifies tests/fixtures/mock_measurement_sequences.lua against the real
-- lua/goals.lua decision functions. This is a regression guard: if goals.lua
-- ever changes (tolerance, epsilon, scoring formula), this test will fail
-- loudly instead of the mock data silently drifting out of sync with the
-- desk logic it's meant to stand in for.
--
-- It does NOT re-simulate fixture response (that lives in
-- tests/gen_mock_sequences.lua) -- it replays the recorded measurements
-- through error_score/has_improved/goals_met and checks the recorded
-- verdicts still match, then checks each fixture's overall outcome
-- (goal met / stagnant auto-accept / hard cap) is internally consistent.

local goals = require("goals")

return function(M)
    local data = require("fixtures/mock_measurement_sequences")
    local target = {
        cct = data.target.cct,
        duv = data.target.duv,
        cri = { mode = goals.GOAL_MIN, value = data.target.cri_min },
        r9  = { mode = goals.GOAL_MIN, value = data.target.r9_min },
    }

    M.section("mock sequences – five fixtures present, covering distinct behaviors")
    M.assert_equal("fixture count", #data.fixtures, 5)

    local behaviors_seen = { met = 0, stagnant = 0, hard_cap = 0 }

    for _, fx in ipairs(data.fixtures) do
        M.section(string.format("mock sequence – %s (fixture %d, %s)",
            fx.name, fx.fixture_id, fx.make_model))

        local prev_score = nil
        local stagnation = { best_score = nil, stagnant_count = 0 }
        local MAX_STAGNANT = 3

        for i, a in ipairs(fx.attempts) do
            local measured = { cct = a.cct, duv = a.duv, cri = a.cri, r9 = a.r9 }
            local score = goals.error_score(measured, target)
            stagnation = goals.update_stagnation(stagnation, measured, score)
            local met = goals.goals_met(measured, target)

            M.assert_near(string.format("%s attempt %d error_score recomputes", fx.name, a.attempt),
                score, a.error_score, 0.01)
            M.assert_equal(string.format("%s attempt %d improved flag", fx.name, a.attempt),
                stagnation.improved, a.improved)
            M.assert_equal(string.format("%s attempt %d goals_met flag", fx.name, a.attempt),
                met, a.goals_met)
            M.assert_equal(string.format("%s attempt %d stagnant_count", fx.name, a.attempt),
                stagnation.stagnant_count, a.stagnant_count)
            if a.reading_plateau ~= nil then
                M.assert_equal(string.format("%s attempt %d reading_plateau", fx.name, a.attempt),
                    stagnation.reading_plateau, a.reading_plateau)
            end

            prev_score = score
        end

        local last = fx.attempts[#fx.attempts]

        if fx.expect_goals_met_at_attempt then
            M.assert_true(fx.name .. " reaches goals_met at recorded attempt",
                last.attempt == fx.expect_goals_met_at_attempt and last.goals_met == true)
            behaviors_seen.met = behaviors_seen.met + 1
        elseif fx.expect_stagnation_at_attempt then
            M.assert_true(fx.name .. " reaches stagnation at recorded attempt",
                last.attempt == fx.expect_stagnation_at_attempt
                and goals.is_stagnated(stagnation, MAX_STAGNANT))
            M.assert_false(fx.name .. " never actually met goal (genuine plateau/stagnation case)",
                last.goals_met)
            behaviors_seen.stagnant = behaviors_seen.stagnant + 1
        elseif fx.expect_hard_cap_hit then
            M.assert_true(fx.name .. " runs the full 12 attempts without resolving",
                #fx.attempts == 12)
            M.assert_false(fx.name .. " never met goal (hard-cap case)", last.goals_met)
            M.assert_false(fx.name .. " never hit stagnation either (hard-cap case)",
                goals.is_stagnated(stagnation, MAX_STAGNANT))
            behaviors_seen.hard_cap = behaviors_seen.hard_cap + 1
        end

        M.assert_true(fx.name .. " never exceeds MAX_ATTEMPTS_HARD=12",
            #fx.attempts <= 12)
    end

    M.section("mock sequences – behavioral coverage")
    M.assert_true("at least one fixture converges to goals_met", behaviors_seen.met >= 1)
    M.assert_true("at least one fixture plateaus into 3x-stagnation auto-accept", behaviors_seen.stagnant >= 1)
    M.assert_true("at least one fixture exhausts the hard attempt cap", behaviors_seen.hard_cap >= 1)
end
