-- Goals domain tests (shared lua/goals.lua).

local goals = require("goals")

return function(M)
    M.section("goals_met – session goal boundaries")
    do
        local g = { cct=5600, duv=0.000, cri={mode=goals.GOAL_SKIP}, r9={mode=goals.GOAL_SKIP}, tlci={mode=goals.GOAL_SKIP} }
        M.assert_true("exact targets met", goals.goals_met({cct=5600, duv=0.000, cri=95, r9=80}, g))
        M.assert_true("CCT +150K pass", goals.goals_met({cct=5750, duv=0.000, cri=95, r9=80}, g))
        M.assert_true("CCT -150K pass", goals.goals_met({cct=5450, duv=0.000, cri=95, r9=80}, g))
        M.assert_false("CCT +151K fail", goals.goals_met({cct=5751, duv=0.000, cri=95, r9=80}, g))
        M.assert_false("CCT -151K fail", goals.goals_met({cct=5449, duv=0.000, cri=95, r9=80}, g))
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
end
