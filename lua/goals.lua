-- goals.lua — Session goal evaluation (pure functions, no MA3 API)
-- Extracted from SekonicCalibrator.lua Sections 2 and 2c.

local M = {}

M.QUALITY = {
    CRI  = { excellent = 95, good = 90, acceptable = 80 },
    R9   = { excellent = 90, good = 80, acceptable = 50 },
    TLCI = { excellent = 90, good = 75, acceptable = 50 },
    DUV  = { excellent = 0.003, good = 0.006, acceptable = 0.010 },
}

M.GOAL_MAX  = "max"
M.GOAL_MIN  = "min"
M.GOAL_SKIP = "skip"

M.CCT_GOAL_TOLERANCE = 100

function M.goal_status_str(measured_val, goal)
    if not goal or goal.mode == M.GOAL_SKIP then return "" end
    if goal.mode == M.GOAL_MAX then return "  [maximize]" end
    if measured_val >= goal.value then
        return string.format("  [GOAL MET \xe2\x89\xa5%d]", goal.value)
    else
        return string.format("  [BELOW GOAL – need %d, have %d]", goal.value, measured_val)
    end
end

-- error_score: a single non-negative number summarizing how far
-- `measured` is from `goals`, normalized so that a value at exactly the
-- tolerance/goal boundary contributes 1.0. Used by the per-fixture
-- auto-correct loop to detect "3 attempts in a row that don't improve"
-- (stagnation) rather than relying on a fixed attempt-count cutoff:
-- comparing this score attempt-to-attempt tells us whether the last
-- correction actually helped, regardless of how far off we started.
-- Lower is better; 0 means every goal is exactly met.
function M.error_score(measured, goals)
    local score = 0
    score = score + math.abs(measured.cct - goals.cct) / M.CCT_GOAL_TOLERANCE
    score = score + math.abs(measured.duv - goals.duv) / M.QUALITY.DUV.acceptable
    if goals.cri and goals.cri.mode == M.GOAL_MIN then
        score = score + math.max(0, goals.cri.value - measured.cri) / 10
    end
    if goals.r9 and goals.r9.mode == M.GOAL_MIN then
        score = score + math.max(0, goals.r9.value - measured.r9) / 10
    end
    if goals.tlci and goals.tlci.mode == M.GOAL_MIN and measured.tlci then
        score = score + math.max(0, goals.tlci.value - measured.tlci) / 10
    end
    return score
end

-- has_improved: true if `score` is at least IMPROVEMENT_EPSILON lower than
-- `prev_score` (i.e. meaningfully better, not just measurement noise).
M.IMPROVEMENT_EPSILON = 0.05
function M.has_improved(score, prev_score)
    if not prev_score then return true end  -- first measurement: nothing to compare
    return (prev_score - score) > M.IMPROVEMENT_EPSILON
end

function M.goals_met(measured, goals)
    if math.abs(measured.cct - goals.cct) > M.CCT_GOAL_TOLERANCE then return false end
    if math.abs(measured.duv - goals.duv) > M.QUALITY.DUV.acceptable then return false end
    if goals.cri  and goals.cri.mode  == M.GOAL_MIN
       and measured.cri  < goals.cri.value  then return false end
    if goals.r9   and goals.r9.mode   == M.GOAL_MIN
       and measured.r9   < goals.r9.value   then return false end
    if goals.tlci and goals.tlci.mode == M.GOAL_MIN
       and measured.tlci and measured.tlci < goals.tlci.value then return false end
    return true
end

return M
