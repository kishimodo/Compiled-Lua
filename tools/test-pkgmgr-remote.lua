-- Remote-registry + outdated/update/gc test. Uses the versioned test registry
-- (package-manager/registry-mv, with index.json + vpkg 1.0.0/2.0.0) as a REMOTE
-- registry via a file:// URL (curl supports file://, so the full remote code
-- path -- index fetch, version resolve, download, install -- runs with no
-- server). Run from the repo root by luavm.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local LUAVM = ROOT .. "\\build\\bin\\luavm.exe"
local PKG   = ROOT .. "\\package-manager\\src\\luavm-pkg.lua"
local URL   = "file:///" .. ROOT:gsub("\\", "/") .. "/package-manager/registry-mv"
local PROJ  = (os.getenv("TEMP") or ".") .. "\\luavm-remotetest"
local STORE = (os.getenv("LOCALAPPDATA") or ".") .. "\\luavm\\packages"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function pk(args) local ok, _, c = os.execute('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i "' .. PKG .. '" ' .. args); return (ok == true) or (ok == 0) or (c == 0) end
local function capture_proj(args) local p = io.popen('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i "' .. PKG .. '" ' .. args .. ' 2>&1'); if not p then return "" end local o = p:read("*a") or ""; p:close(); return o end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function fail(m) print("[-] FAIL test-pkgmgr-remote: " .. m); sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1'); os.exit(1) end

sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1'); sh('mkdir "' .. PROJ .. '" >nul 2>&1')
sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1')

-- 1) add from the REMOTE (file://) registry, exact 1.0.0 -> downloaded + locked
if not pk('add vpkg "' .. URL .. '" "1.0.0" >nul 2>&1') then fail("remote add vpkg 1.0.0") end
local lock = slurp(PROJ .. "\\luavm.lock") or ""
if not lock:match('%["vpkg"%].-version%s*=%s*"1%.0%.0"') then fail("lock should pin 1.0.0, got: " .. lock:gsub("%s+", " ")) end
if not slurp(STORE .. "\\vpkg\\1.0.0\\init.lua") then fail("vpkg 1.0.0 not downloaded into the store") end

-- 2) outdated reports the newer 2.0.0 available
local od = capture_proj('outdated "' .. URL .. '"')
if not od:match("2%.0%.0") then fail("outdated should report 2.0.0 available, got: " .. od:gsub("%s+", " ")) end

-- 3) widen the constraint, then update bumps the lock to 2.0.0 (also pulls 2.0.0
--    from the remote so the store now holds both versions)
spit(PROJ .. "\\luavm.toml", "[dependencies]\nvpkg = \">=1.0.0\"\n")
if not pk('update vpkg "' .. URL .. '" >nul 2>&1') then fail("update vpkg") end
lock = slurp(PROJ .. "\\luavm.lock") or ""
if not lock:match('%["vpkg"%].-version%s*=%s*"2%.0%.0"') then fail("update should bump lock to 2.0.0, got: " .. lock:gsub("%s+", " ")) end

-- 4) gc prunes the now-unreferenced 1.0.0 (lock pins 2.0.0, which is also latest)
if not (slurp(STORE .. "\\vpkg\\1.0.0\\init.lua") and slurp(STORE .. "\\vpkg\\2.0.0\\init.lua")) then
  fail("store should hold both versions before gc")
end
if not pk('gc >nul 2>&1') then fail("gc") end
if slurp(STORE .. "\\vpkg\\1.0.0\\init.lua") then fail("gc should have pruned unreferenced 1.0.0") end
if not slurp(STORE .. "\\vpkg\\2.0.0\\init.lua") then fail("gc must keep the locked/latest 2.0.0") end

sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1')
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1')
print("[+] PASS test-pkgmgr-remote (file:// remote add + outdated + update bump + gc prune)")
os.exit(0)
