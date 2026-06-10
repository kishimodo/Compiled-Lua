-- Lockfile-reproducibility test (Bug 2): a committed luavm.lock must give
-- reproducible installs (npm-ci semantics). Project-mode `install` (no package
-- arg) must install the EXACTLY pinned version even when the toml constraint has
-- been widened -- it must NOT silently re-resolve/upgrade. Only `update`/`add`
-- may move a pin. Uses the versioned registry (registry-mv: vpkg 1.0.0 + 2.0.0).
-- Run from the repo root by luavm.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local LUAVM = ROOT .. "\\build\\bin\\luavm.exe"
local PKG   = ROOT .. "\\package-manager\\src\\luavm-pkg.lua"
local REG   = ROOT .. "\\package-manager\\registry-mv"
local PROJ  = (os.getenv("TEMP") or ".") .. "\\luavm-locktest"

local function sh(c) local ok, _, code = os.execute('"' .. c .. '"'); return (ok == true) or (ok == 0) or (code == 0) end
local function pk(a) local ok, _, c = os.execute('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i "' .. PKG .. '" ' .. a); return (ok == true) or (ok == 0) or (c == 0) end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function fail(m) print("[-] FAIL test-pkgmgr-lockfile: " .. m); sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1'); os.exit(1) end

sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1'); sh('mkdir "' .. PROJ .. '" >nul 2>&1')
sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1')

-- 1) Pin to exactly 1.0.0 via add (writes luavm.toml + luavm.lock).
if not pk('add vpkg "' .. REG .. '" "1.0.0" >nul 2>&1') then fail("add vpkg 1.0.0") end
local lock = slurp(PROJ .. "\\luavm.lock") or ""
if not lock:match('%["vpkg"%].-version%s*=%s*"1%.0%.0"') then fail("lock should pin 1.0.0 after add") end

-- 2) WIDEN the toml constraint to allow 2.0.0, but DO NOT touch the lock.
spit(PROJ .. "\\luavm.toml", '[dependencies]\nvpkg = ">=1.0.0"\n')

-- 3) Project install (no package arg) with a lock present must keep 1.0.0
--    (reproducible) -- NOT upgrade to 2.0.0 despite the widened constraint.
if not pk('install --registry "' .. REG .. '" >nul 2>&1') then fail("project install (ci) should succeed") end
lock = slurp(PROJ .. "\\luavm.lock") or ""
if lock:match('version%s*=%s*"2%.0%.0"') then fail("BUG2: project install upgraded to 2.0.0 despite the lock pinning 1.0.0") end
if not lock:match('%["vpkg"%].-version%s*=%s*"1%.0%.0"') then fail("lock no longer pins 1.0.0 after ci install") end

-- 4) The installed store content for vpkg must be 1.0.0 (the pinned bytes).
do
  local STORE = os.getenv("LUAVM_HOME")
  if STORE and STORE ~= "" then STORE = STORE .. "\\packages"
  else STORE = (os.getenv("LOCALAPPDATA") or ".") .. "\\luavm\\packages" end
  local which = slurp(STORE .. "\\vpkg\\init.lua") or ""
  if not which:match("1%.0%.0") then fail("active store content is not vpkg 1.0.0 after ci install (got mismatch)") end
end

-- 5) Re-running ci install must be idempotent and STILL 1.0.0.
if not pk('install --registry "' .. REG .. '" >nul 2>&1') then fail("second ci install should succeed") end
lock = slurp(PROJ .. "\\luavm.lock") or ""
if lock:match('version%s*=%s*"2%.0%.0"') then fail("BUG2: repeated ci install drifted to 2.0.0") end

-- 6) `update` IS allowed to move the pin (widened constraint -> 2.0.0).
if not pk('update vpkg "' .. REG .. '" >nul 2>&1') then fail("update vpkg") end
lock = slurp(PROJ .. "\\luavm.lock") or ""
if not lock:match('%["vpkg"%].-version%s*=%s*"2%.0%.0"') then fail("update should move the pin to 2.0.0") end

sh(LUAVM .. ' -i ' .. PKG .. ' remove vpkg >nul 2>&1')
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1')
print("[+] PASS test-pkgmgr-lockfile (lock honored on install; widened toml does not upgrade; update can)")
os.exit(0)
