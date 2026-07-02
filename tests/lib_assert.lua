-- Shared assertion harness for Lighttune host tests.
-- Used by tests/run.lua and domain test modules under tests/.

local M = {}

M.PASS = 0
M.FAIL = 0

function M.reset()
    M.PASS = 0
    M.FAIL = 0
end

function M.get_counts()
    return M.PASS, M.FAIL
end

function M.assert_near(label, got, expected, tolerance)
    tolerance = tolerance or 0.0005
    if math.abs(got - expected) <= tolerance then
        print(string.format("  PASS  %s  (got %.6f, expected %.6f)", label, got, expected))
        M.PASS = M.PASS + 1
    else
        print(string.format("  FAIL  %s  (got %.6f, expected %.6f, diff %.6f)",
            label, got, expected, math.abs(got - expected)))
        M.FAIL = M.FAIL + 1
    end
end

function M.assert_equal(label, got, expected)
    if got == expected then
        print(string.format("  PASS  %s  (got '%s')", label, tostring(got)))
        M.PASS = M.PASS + 1
    else
        print(string.format("  FAIL  %s  (got '%s', expected '%s')",
            label, tostring(got), tostring(expected)))
        M.FAIL = M.FAIL + 1
    end
end

function M.assert_true(label, condition)
    if condition then
        print(string.format("  PASS  %s", label))
        M.PASS = M.PASS + 1
    else
        print(string.format("  FAIL  %s  (expected true)", label))
        M.FAIL = M.FAIL + 1
    end
end

function M.assert_false(label, condition)
    if not condition then
        print(string.format("  PASS  %s", label))
        M.PASS = M.PASS + 1
    else
        print(string.format("  FAIL  %s  (expected false)", label))
        M.FAIL = M.FAIL + 1
    end
end

function M.section(name)
    print("\n[" .. name .. "]")
end

return M
