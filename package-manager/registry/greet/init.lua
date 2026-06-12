-- Sample third-party package living in the local test registry. Installed via
-- `luavm-pkg install greet`, after which any project can `require "greet"`.
local M = {}

function M.hello(name)
  return "Hello, " .. (name or "world") .. "!"
end

function M.shout(name)
  return M.hello(name):upper()
end

M.version = "1.0.0"

return M
