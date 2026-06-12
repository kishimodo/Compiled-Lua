-- mid -- middle of the dependency graph; depends on leaf ^1.0.0 (v1.0.0).
local leaf = require("leaf")
local M = {}
M.version = "1.0.0"
function M.chain() return "mid-1.0.0/" .. leaf.who() end
return M
