-- aot_builtinpkg.lua - builtin packages bundle into compiled programs: the
-- driver compiles each required builtin's source as an ordinary module and
-- preload-registers it (same machinery as rover-installed packages).
package.path = "clua\\\\src\\\\runtime\\\\packages\\\\?\\\\init.lua;" .. package.path  -- oracle host path; the exe uses preload
local json = require "json"
local base64 = require "base64"
local s = json.encode({ list = {1, 2, 3} })
print(s)
local t = json.decode(s)
print(t.list[1] + t.list[2] + t.list[3])
print(base64.encode("CLua"))
print(base64.decode(base64.encode("round-trip")))
