-- Goals domain tests (shared lua/goals.lua).

local goals = require("goals")

return function(M)
    M.section("goals_met – session goal boundaries")
    do
        local g = { cct=5600, duv=0.000, cri={mode=goals.GOAL_SKIP}, r9={mode=goals.GOAL_SKIP}, tlci={mode=goals.GOAL_SKIP} }
        M.assert_true("exact targets met", goals.goals_met({cct=5600, duv=0.000, cri=95, r9=80}, g))
        M.assert_true("CCT +100K pass", goals.goals_met({cct=5700, duv=0.000, cri=95, r9=80}, g))
        M.assert_true("CCT -100K pass", goals.goals_met({cct=5500, duv=0.000, cri=95, r9=80}, g))
        M.assert_false("CCT +101K fail", goals.goals_met({cct=5701, duv=0.000, cri=95, r9=80}, g))
        M.assert_false("CCT -101K fail", goals.goals_met({cct=5499, duv=0.000, cri=95, r9=80}, g))
        M.assert_true("Duv at tolerance pass", goals.goals_met({cct=5600, duv=0.010, cri=95, r9=80}, g))
        M.assert_false("Duv over tolerance fail", goals.goals_met({cct=5600, duv=0.011, cri=95, r9=80}, g))
        g.cri = {mode=goals.GOAL_MIN, value=90}
        M.assert_true("CRI goal met", goals.goals_met({cct=5600, duv=0.000, cri=90, r9=80}, g))
        M.assert_false("CRI goal below", goals.goals_met({cct=5600, duv=0.000, cri=89, r9=80}, g))
        g.tlci = {mode=goals.GOAL_MIN, value=75}
        M.assert_true("TLCI nil ignored when missing", goals.goals_met({cct=5600, duv=0.000, cri=95, r9=80, tlci=nil}, g))
    end

    M.section("goal_status_str")
    do
        M.assert_equal("GOAL_SKIP empty", goals.goal_status_str(95, {mode=goals.GOAL_SKIP}), "")
        M.assert_equal("GOAL_MAX maximize", goals.goal_status_str(95, {mode=goals.GOAL_MAX}), "  [maximize]")
        M.assert_true("GOAL_MIN met contains GOAL MET", goals.goal_status_str(95, {mode=goals.GOAL_MIN, value=90}):find("GOAL MET") ~= nil)
    end

    M.section("error_score – normalized distance from goals")
    do
        local g = { cct=3200, duv=0.000, cri={mode=goals.GOAL_MIN, value=90}, r9={mode=goals.GOAL_MIN, value=50} }
        M.assert_near("exact match scores 0", goals.error_score({cct=3200, duv=0.000, cri=90, r9=50}, g), 0.0, 0.001)
        M.assert_near("CCT-only offset scales by tolerance", goals.error_score({cct=3300, duv=0.000, cri=90, r9=50}, g), 1.0, 0.001)
        M.assert_near("Duv-only offset scales by acceptable band", goals.error_score({cct=3200, duv=0.010, cri=90, r9=50}, g), 1.0, 0.001)
        M.assert_near("CRI shortfall adds 0.1 per point", goals.error_score({cct=3200, duv=0.000, cri=85, r9=50}, g), 0.5, 0.001)
        M.assert_near("R9 shortfall adds 0.1 per point", goals.error_score({cct=3200, duv=0.000, cri=90, r9=40}, g), 1.0, 0.001)
        M.assert_near("CRI/R9 above goal contributes nothing extra", goals.error_score({cct=3200, duv=0.000, cri=99, r9=99}, g), 0.0, 0.001)
        M.assert_true("further-off measurement scores higher",
            goals.error_score({cct=3600, duv=0.000, cri=90, r9=50}, g) >
            goals.error_score({cct=3300, duv=0.000, cri=90, r9=50}, g))
    end

    M.section("has_improved – stagnation-detection threshold")
    do
        M.assert_true("first measurement always counts as improved (no prior score)", goals.has_improved(5.0, nil))
        M.assert_true("clear improvement beyond epsilon", goals.has_improved(1.0, 2.0))
        M.assert_false("improvement below epsilon does not count", goals.has_improved(1.97, 2.0))
        M.assert_false("improvement well under epsilon does not count", goals.has_improved(1.98, 2.0))
        M.assert_true("just over epsilon boundary counts", goals.has_improved(1.9499, 2.0))
        M.assert_false("no change does not count", goals.has_improved(2.0, 2.0))
        M.assert_false("regression (worse score) does not count", goals.has_improved(2.5, 2.0))
    end
end
