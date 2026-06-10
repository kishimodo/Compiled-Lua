-- Consumer project for the R6 end-to-end test: requires the installed
-- third-party package `greet`. The static require "greet" lets compiler.exe
-- resolve + bundle it from the global store; luavm.exe -i resolves it from
-- the store via package.path.
local greet = require "greet"
local function check(c, m) if not c then io.stderr:write("FAIL: " .. m .. "\n"); os.exit(1) end end

check(greet.hello("LuaVM") == "Hello, LuaVM!", "greet.hello")
check(greet.shout("hey")  == "HELLO, HEY!",   "greet.shout")
check(greet.version == "1.0.0",               "greet.version")

print("greet ok")
os.exit(0)
