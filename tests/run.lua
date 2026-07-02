-- Lighttune host test runner (single entry point).
-- Assumes cwd is the repository root when invoked as: lua5.4 tests/run.lua

-- Replace default path so require("test_color_math") resolves tests/, not root wrapper.
package.path = "./lua/?.lua;./tests/?.lua"

local M = require("lib_assert")
M.reset()

local run_color_math = require("test_color_math")
local run_fixture_db = require("test_fixture_db")
local run_goals = require("test_goals")
local run_bridge_client = require("test_bridge_client")

run_color_math(M)
run_fixture_db(M)
run_goals(M)
run_bridge_client(M)

local PASS, FAIL = M.get_counts()

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", PASS, FAIL))
print(string.format("========================================"))

if FAIL > 0 then os.exit(1) end
