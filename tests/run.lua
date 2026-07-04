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
local run_mock_sequences = require("test_mock_sequences")
local run_gdtf_caps = require("test_gdtf_caps")
local run_closed_loop = require("test_closed_loop")

run_color_math(M)
run_fixture_db(M)
run_goals(M)
run_bridge_client(M)
run_closed_loop(M)
run_mock_sequences(M)
run_gdtf_caps(M)

local PASS, FAIL = M.get_counts()

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", PASS, FAIL))
print(string.format("========================================"))

if FAIL > 0 then os.exit(1) end
