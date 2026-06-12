-- app -- top of the dependency graph; depends on mid ^1.0.0 (v1.0.0).
local mid = require("mid")
local M = {}
M.version = "1.0.0"
function M.run() return "app-1.0.0/" .. mid.chain() end
return M
