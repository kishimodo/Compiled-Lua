-- mfpkg -- multi-file test package (entry point).
local helper = require("mfpkg.helper")
local M = {}
M.version = "1.0.0"
function M.greet() return "mfpkg:" .. helper.tag() end
return M
