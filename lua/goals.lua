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

-- Plateau detection: last N readings all within this CCT/Duv spread means
-- the fixture is no longer moving — stop even if error_score noise flickers.
M.STAGNANT_WINDOW       = 3
M.STAGNANT_READING_CCT_K = 50
M.STAGNANT_READING_DUV   = 0.004

function M.readings_window_flat(readings, cct_tol, duv_tol)
    cct_tol = cct_tol or M.STAGNANT_READING_CCT_K
    duv_tol = duv_tol or M.STAGNANT_READING_DUV
    if not readings or #readings < M.STAGNANT_WINDOW then
        return false
    end
    local min_cct, max_cct = readings[1].cct, readings[1].cct
    local min_duv, max_duv = readings[1].duv, readings[1].duv
    for i = 2, #readings do
        local r = readings[i]
        if r.cct < min_cct then min_cct = r.cct end
        if r.cct > max_cct then max_cct = r.cct end
        if r.duv < min_duv then min_duv = r.duv end
        if r.duv > max_duv then max_duv = r.duv end
    end
    return (max_cct - min_cct) <= cct_tol and (max_duv - min_duv) <= duv_tol
end

-- Track consecutive attempts that fail to improve vs the previous reading,
-- and whether the last STAGNANT_WINDOW CCT/Duv readings sit in a tight band.
function M.update_stagnation(state, measured, score)
    state = state or {}

    if not state.best_score or M.has_improved(score, state.best_score) then
        state.best_score = score
    end

    local improved_vs_last = not state.last_score or M.has_improved(score, state.last_score)
    if improved_vs_last then
        state.stagnant_count = 0
    else
        state.stagnant_count = (state.stagnant_count or 0) + 1
    end
    state.last_score = score

    state.recent_readings = state.recent_readings or {}
    state.recent_readings[#state.recent_readings + 1] = {
        cct = measured.cct,
        duv = measured.duv,
    }
    while #state.recent_readings > M.STAGNANT_WINDOW do
        table.remove(state.recent_readings, 1)
    end
    state.reading_plateau = M.readings_window_flat(state.recent_readings)

    state.recent_scores = state.recent_scores or {}
    state.recent_scores[#state.recent_scores + 1] = score
    while #state.recent_scores > M.STAGNANT_WINDOW do
        table.remove(state.recent_scores, 1)
    end
    if #state.recent_scores >= M.STAGNANT_WINDOW then
        local min_s, max_s = state.recent_scores[1], state.recent_scores[1]
        for i = 2, #state.recent_scores do
            local s = state.recent_scores[i]
            if s < min_s then min_s = s end
            if s > max_s then max_s = s end
        end
        if (max_s - min_s) <= M.IMPROVEMENT_EPSILON then
            state.score_plateau = true
        else
            state.score_plateau = false
        end
    else
        state.score_plateau = false
    end

    return state
end

function M.is_stagnated(state, max_stagnant)
    max_stagnant = max_stagnant or M.STAGNANT_WINDOW
    if not state then return false end
    if state.reading_plateau or state.score_plateau then return true end
    return (state.stagnant_count or 0) >= max_stagnant
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
