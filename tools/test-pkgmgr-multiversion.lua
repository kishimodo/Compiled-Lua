-- Multi-version test: two projects can depend on different versions of one
-- package. Uses the versioned test registry (package-manager/registry-mv, with
-- vpkg 1.0.0 + 2.0.0). Locks a temp project to a version, compiles a program
-- that `require`s vpkg (the compiler resolves the lock-pinned version), runs it,
-- and checks which version was bundled -- then re-locks and reconfirms. Also
-- checks the interpreter (-i) resolves the locked version. Run from the repo
-- root by luavm.exe (so the compiler finds its build/bin libs).

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local LUAVM = ROOT .. "\\build\\bin\\luavm.exe"
local COMP  = ROOT .. "\\build\\bin\\compiler.exe"
local PKG   = ROOT .. "\\package-manager\\src\\luavm-pkg.lua"
local REG   = ROOT .. "\\package-manager\\registry-mv"
local PROJ  = (os.getenv("TEMP") or ".") .. "\\luavm-mvtest"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function pk(args)  -- pkg manager, run IN the project dir (writes toml/lock there)
  local ok, _, c = os.execute('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i "' .. PKG .. '" ' .. args)
  return (ok == true) or (ok == 0) or (c == 0)
end
local function capture(cmd) local p = io.popen('"' .. cmd .. '" 2>&1'); if not p then return "" end local o = p:read("*a") or ""; p:close(); return o end
local function fail(m) print("[-] FAIL test-pkgmgr-multiversion: " .. m); sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1'); os.exit(1) end

sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1'); sh('mkdir "' .. PROJ .. '" >nul 2>&1')
sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1')
do local f = io.open(PROJ .. "\\main.lua", "wb"); f:write('print("R:" .. require("vpkg").which())\n'); f:close() end

-- compile main.lua (from the repo root cwd, so libs resolve; the compiler reads
-- the lock from the SOURCE dir = PROJ) and run the produced exe; return output.
local function build_and_run(tag)
  local exe = PROJ .. "\\app_" .. tag .. ".exe"
  if not sh(COMP .. ' -o "' .. exe .. '" "' .. PROJ .. '\\main.lua" >nul 2>&1') then fail("compile (" .. tag .. ")") end
  return capture('"' .. exe .. '"')
end

-- 1) lock to exactly 1.0.0 -> compiler bundles 1.0.0
if not pk('add vpkg "' .. REG .. '" "1.0.0" >nul 2>&1') then fail("add vpkg 1.0.0") end
local out1 = build_and_run("v1")
if not out1:match("R:vpkg%-1%.0%.0") then fail("expected vpkg-1.0.0, got: " .. out1:gsub("%s+", " ")) end

-- 2) re-lock to 2.0.0 -> compiler bundles 2.0.0 (multi-version coexistence)
if not pk('add vpkg "' .. REG .. '" "2.0.0" >nul 2>&1') then fail("add vpkg 2.0.0") end
local out2 = build_and_run("v2")
if not out2:match("R:vpkg%-2%.0%.0") then fail("expected vpkg-2.0.0, got: " .. out2:gsub("%s+", " ")) end

-- 3) semver caret: ^1.0.0 must resolve to 1.0.0 (not 2.0.0)
if not pk('add vpkg "' .. REG .. '" "^1.0.0" >nul 2>&1') then fail("add vpkg ^1.0.0") end
local out3 = build_and_run("v3")
if not out3:match("R:vpkg%-1%.0%.0") then fail("^1.0.0 should resolve to 1.0.0, got: " .. out3:gsub("%s+", " ")) end

-- 4) the interpreter (-i) resolves the locked version too (lock=^1.0.0 -> 1.0.0)
local iout = capture('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i main.lua')
if not iout:match("R:vpkg%-1%.0%.0") then fail("interpreter should resolve 1.0.0, got: " .. iout:gsub("%s+", " ")) end

sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1')
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1')
print("[+] PASS test-pkgmgr-multiversion (compiler + interpreter resolve lock-pinned versions; semver ^ works)")
os.exit(0)
