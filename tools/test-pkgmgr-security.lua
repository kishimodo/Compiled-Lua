-- Security test (Bug 1): command-injection hardening. A package `name` is
-- attacker-controlled (CLI, rover.toml, AND a remote registry's index.json) and
-- ends up inside shell command strings (io.popen/os.execute). A name containing
-- a quote/`&`/`|`/path-separator must be REJECTED before any command runs --
-- otherwise a compromised registry => local code execution. Run by clua-interp.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local CLUA = ROOT .. "\\build\\bin\\clua-interp.exe"
local CLUA_BUILD = ROOT .. "\\build\\bin\\clua.exe"
local PKG   = ROOT .. "\\rover\\src\\rover.lua"
local MARK  = (os.getenv("TEMP") or ".") .. "\\clua-interp-pwned-marker.txt"

local function sh(c) local ok, _, code = os.execute('"' .. c .. '"'); return (ok == true) or (ok == 0) or (code == 0) end
local function fail(m) print("[-] FAIL test-pkgmgr-security: " .. m); os.exit(1) end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

-- Run the manager with ONE argv element = `name`, forcing the breakout payload
-- through as a single argument. We build the command for cmd.exe ourselves and
-- escape inner quotes so the bad name reaches the program intact.
local function run_install(name)
  os.remove(MARK)
  local escaped = name:gsub('"', '\\"')
  -- outer-quote the whole command (os.execute -> cmd.exe), inner-quote the arg
  local cmd = '""' .. CLUA .. '" -i "' .. PKG .. '" install "' .. escaped .. '" >nul 2>nul"'
  local ok, _, code = os.execute(cmd)
  local rc = (type(code) == "number") and code or (ok == true and 0 or 1)
  return rc
end

-- 1) A name with shell metacharacters that, if injected, would create MARK.
local payloads = {
  'x" 2>nul & echo PWNED > "' .. MARK .. '" & rem ',  -- quote breakout + redirect
  'x" | echo PWNED > "' .. MARK .. '" & rem ',         -- pipe breakout
  '..\\..\\evil',                                        -- path traversal
  'a b',                                                 -- space
  'name;rm',                                             -- semicolon
}
for _, p in ipairs(payloads) do
  run_install(p)
  if slurp(MARK) then
    os.remove(MARK)
    fail("command injection: payload created the marker file -> arbitrary command ran (" .. p .. ")")
  end
end
os.remove(MARK)

-- 2) The validator must REJECT malformed names with exit code 2 (usage/validation),
--    not 1 (a valid-but-missing package). A clearly-invalid name:
do
  local rc = run_install('bad/name')
  if rc ~= 2 then fail("invalid name 'bad/name' should exit 2 (validation), got " .. tostring(rc)) end
end

-- 3) A WELL-FORMED but absent name must pass validation and fail at lookup
--    (exit 1) -- proving the allowlist is not over-broad.
do
  local rc = run_install('totally-absent_pkg.v2')
  if rc ~= 1 then fail("valid-but-absent name should exit 1 (lookup), got " .. tostring(rc)) end
end

-- 4) name_ok unit table via the test hook (covers the data-sourced boundary too).
sh('set ROVER_PKG_TEST=1')   -- noop on this shell; we set it via the child env below
local driver = (os.getenv("TEMP") or ".") .. "\\clua-interp-secdriver.lua"
do
  local f = io.open(driver, "wb")
  f:write([[
dofile("rover/src/rover.lua")
local M = _G.ROVER_PKG
local good = { "greet", "a.b-c_1", "x", string.rep("a",128) }
local bad  = { "", "a b", 'a"b', "a&b", "a|b", "a/b", "a\\b", "..", "../x", ".hidden", "-flag",
               "a;b", "a$b", "a`b", "a\nb", "a..b", string.rep("a",129) }
for _, n in ipairs(good) do if not M.name_ok(n) then print("BADGOOD:"..n); os.exit(3) end end
for _, n in ipairs(bad)  do if M.name_ok(n)     then print("BADBAD:"..n);  os.exit(4) end end
print("UNIT_OK")
]])
  f:close()
end
local p = io.popen('set "ROVER_PKG_TEST=1" && "' .. CLUA .. '" -i "' .. driver .. '" 2>nul')
local out = p and p:read("*a") or ""
if p then p:close() end
os.remove(driver)
if not out:match("UNIT_OK") then fail("name_ok allowlist unit check failed: " .. (out:gsub("%s+", " "))) end

-- 5) A checked-in rover.lock is untrusted input too. Its version field becomes
-- a package-store path segment in both clua-interp and clua build. A traversal
-- must be rejected rather than loading/compiling a Lua file outside the store.
do
  local box = (os.getenv("TEMP") or ".") .. "\\clua-lock-version-security"
  local home, proj = box .. "\\home", box .. "\\project"
  local marker = box .. "\\executed.txt"
  local function put(path, content)
    local dir = path:match("^(.*)\\[^\\]+$")
    if dir then sh('mkdir "' .. dir .. '" >nul 2>&1') end
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
  end
  local function capture(cmd)
    local p = io.popen("(" .. cmd .. ") 2>&1")
    if not p then return -1, "" end
    local text = p:read("*a") or ""
    local ok, _, code = p:close()
    return ok == true and 0 or (code or 1), text
  end

  sh('rmdir /S /Q "' .. box .. '" >nul 2>&1')
  put(home .. "\\payload\\init.lua",
      "local f=assert(io.open(" .. string.format("%q", marker) ..
      ",'wb')); f:write('PWNED'); f:close(); return {}\n")
  put(proj .. "\\rover.lock", [=[return {
  ["evilpkg"] = { version = "..\..\payload", hash = "x" },
}
]=])
  put(proj .. "\\app.lua", 'require("evilpkg")\nprint("unexpected")\n')

  local prefix = 'set "CLUA_HOME=' .. home .. '" && cd /d "' .. proj .. '" && '
  local irc, iout = capture(prefix .. '"' .. CLUA .. '" -i app.lua')
  if irc == 0 or slurp(marker) then
    sh('rmdir /S /Q "' .. box .. '" >nul 2>&1')
    fail("clua-interp accepted a traversal version from rover.lock: " ..
         (iout:gsub("%s+", " ")))
  end
  local brc, bout = capture(prefix .. '"' .. CLUA_BUILD .. '" build app.lua -o app.exe')
  if brc == 0 or slurp(marker) then
    sh('rmdir /S /Q "' .. box .. '" >nul 2>&1')
    fail("clua build accepted a traversal version from rover.lock: " ..
         (bout:gsub("%s+", " ")))
  end
  sh('rmdir /S /Q "' .. box .. '" >nul 2>&1')
end

print("[+] PASS test-pkgmgr-security (malicious names/lock versions rejected; no command injection; allowlists correct)")
os.exit(0)
