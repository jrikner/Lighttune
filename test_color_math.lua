-- Backward-compat wrapper — delegates to tests/run.lua.
-- Prefer: lua5.4 tests/run.lua

package.path = "./lua/?.lua;./tests/?.lua"
dofile("tests/run.lua")
