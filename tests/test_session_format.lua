-- tests/test_session_format.lua — goals_summary_line format (Phase 6)

return function(M)
    package.path = "./lua/?.lua;" .. package.path
    local session_ui = require("ui.session")
    local goal_eval  = require("goals")

    print("\n--- goals_summary_line ---")

    local goals_target = {
        mode = "target",
        cct = 5600,
        duv = 0.000,
        cri = { mode = goal_eval.GOAL_MAX },
        r9  = { mode = goal_eval.GOAL_MIN, value = 80 },
        tlci = { mode = goal_eval.GOAL_SKIP },
    }
    local line = session_ui.goals_summary_line(goals_target)
    M.assert_equal("target mode line contains 5600K", line:find("5600K") ~= nil, true)
    M.assert_equal("target mode CRI:max", line:find("CRI:max") ~= nil, true)
    M.assert_equal("target mode R9 min", line:find("R9:") ~= nil, true)
    M.assert_equal("no Ref prefix in target mode", line:find("Ref:") ~= nil, false)

    local goals_ref = {
        mode = "reference",
        ref_group = "Key Light",
        cct = 3200,
        duv = 0.003,
        cri = { mode = goal_eval.GOAL_SKIP },
        r9  = { mode = goal_eval.GOAL_SKIP },
        tlci = { mode = goal_eval.GOAL_SKIP },
    }
    local ref_line = session_ui.goals_summary_line(goals_ref)
    M.assert_equal("reference mode Ref prefix", ref_line:find("Ref: Key Light") ~= nil, true)
    M.assert_equal("reference mode Duv offset", ref_line:find("Duv%+0%.003") ~= nil, true)
end
