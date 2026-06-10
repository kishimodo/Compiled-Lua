-- Transitive dependency resolution test (Feature 4). A package declares
-- `dependencies` (name -> range) in package.lua; the manager recursively
-- resolves + installs them with semver, records the full resolved graph in
-- luavm.lock, and detects conflicts (two incompatible ranges for one package).
-- Fixtures live in registry-test:
--   app@1.0.0 -> mid ^1.0.0 -> leaf ^1.0.0   (2-level graph)
--   conflictdep@1.0.0 -> leaf ^2.0.0          (to clash with leaf ^1.0.0)
-- Run from the repo root by luavm.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local LUAVM = ROOT .. "\\build\\bin\\luavm.exe"
local PKG   = ROOT .. "\\package-manager\\src\\luavm-pkg.lua"
local REG   = ROOT .. "\\package-manager\\registry-test"
local PROJ  = (os.getenv("TEMP") or ".") .. "\\luavm-depstest"

local function sh(c) local ok, _, code = os.execute('"' .. c .. '"'); return (ok == true) or (ok == 0) or (code == 0) end
local function pk(a) local ok, _, c = os.execute('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i "' .. PKG .. '" ' .. a); return (ok == true) or (ok == 0) or (c == 0) end
local function pkout(a) local p = io.popen('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i "' .. PKG .. '" ' .. a .. ' 2>&1'); if not p then return "" end local o = p:read("*a") or ""; p:close(); return o end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function cleanup() for _, n in ipairs({ "app", "mid", "leaf", "conflictdep" }) do sh(LUAVM .. ' -i ' .. PKG .. ' remove ' .. n .. ' >nul 2>&1') end end
local function fail(m) print("[-] FAIL test-pkgmgr-deps: " .. m); cleanup(); os.exit(1) end

sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1'); sh('mkdir "' .. PROJ .. '" >nul 2>&1')
cleanup()

-- 1) add app -> the manager must transitively install app, mid AND leaf.
if not pk('add app "' .. REG .. '" >nul 2>&1') then fail("add app (transitive)") end
local lock = slurp(PROJ .. "\\luavm.lock") or ""
if not lock:match('%["app"%].-version%s*=%s*"1%.0%.0"') then fail("lock missing app 1.0.0") end
if not lock:match('%["mid"%].-version%s*=%s*"1%.0%.0"') then fail("lock missing transitive dep mid 1.0.0") end
if not lock:match('%["leaf"%].-version%s*=%s*"1%.0%.0"') then fail("lock missing transitive dep leaf 1.0.0") end

-- 2) the lock records the dependency EDGES (the resolved graph), not just nodes.
if not lock:match('%["app"%].-deps%s*=%s*{[^}]-%["mid"%]') then fail("lock should record app -> mid edge") end
if not lock:match('%["mid"%].-deps%s*=%s*{[^}]-%["leaf"%]') then fail("lock should record mid -> leaf edge") end

-- 3) the transitive packages are actually installed in the store and requirable.
do
  spit(PROJ .. "\\main.lua", 'print("OUT:" .. require("app").run())\n')
  local iout = pkout('where')   -- ensure manager works; then run the program
  local p = io.popen('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i main.lua 2>&1')
  local o = p and p:read("*a") or ""; if p then p:close() end
  if not o:match("OUT:app%-1%.0%.0/mid%-1%.0%.0/leaf%-1%.0%.0") then
    fail("transitively-installed graph not requirable end-to-end (got: " .. o:gsub("%s+", " ") .. ")")
  end
end

-- 4) CONFLICT: a project requiring leaf ^1.0.0 AND conflictdep (which needs
--    leaf ^2.0.0) has no single leaf satisfying both -> a clear error, no lock.
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1'); sh('mkdir "' .. PROJ .. '" >nul 2>&1')
cleanup()
spit(PROJ .. "\\luavm.toml", '[dependencies]\nleaf = "^1.0.0"\nconflictdep = "^1.0.0"\n')
local cout = pkout('install --registry "' .. REG .. '"')
if not cout:match("[Cc]onflict") then fail("expected a dependency conflict error, got: " .. cout:gsub("%s+", " ")) end
if pk('install --registry "' .. REG .. '" >nul 2>&1') then fail("conflicting install should exit non-zero") end

cleanup()
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1')
print("[+] PASS test-pkgmgr-deps (transitive resolve+install, graph recorded in lock, conflict detected)")
os.exit(0)
