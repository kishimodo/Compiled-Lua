-- Security test (Bug 1): command-injection hardening. A package `name` is
-- attacker-controlled (CLI, rover.toml, AND a remote registry's index.json) and
-- ends up inside shell command strings (io.popen/os.execute). A name containing
-- a quote/`&`/`|`/path-separator must be REJECTED before any command runs --
-- otherwise a compromised registry => local code execution. Run by luavm.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local LUAVM = ROOT .. "\\build\\bin\\luavm.exe"
local PKG   = ROOT .. "\\rover\\src\\rover.lua"
local MARK  = (os.getenv("TEMP") or ".") .. "\\luavm-pwned-marker.txt"

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
  local cmd = '""' .. LUAVM .. '" -i "' .. PKG .. '" install "' .. escaped .. '" >nul 2>nul"'
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
local driver = (os.getenv("TEMP") or ".") .. "\\luavm-secdriver.lua"
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
local p = io.popen('set "ROVER_PKG_TEST=1" && "' .. LUAVM .. '" -i "' .. driver .. '" 2>nul')
local out = p and p:read("*a") or ""
if p then p:close() end
os.remove(driver)
if not out:match("UNIT_OK") then fail("name_ok allowlist unit check failed: " .. (out:gsub("%s+", " "))) end

print("[+] PASS test-pkgmgr-security (malicious names rejected; no command injection; allowlist correct)")
os.exit(0)
