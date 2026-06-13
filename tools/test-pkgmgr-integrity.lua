-- Whole-tree integrity test (Bug 3). Hashing only init.lua lets a swapped
-- HELPER file in a multi-file package still verify and ship. The manager now
-- records a Merkle-style root over ALL files (sorted relative paths + per-file
-- sha256) in the manifest AND the lock, and `verify` checks it. This test
-- installs a 2-file package (mfpkg: init.lua + helper.lua), tampers ONLY
-- helper.lua, and asserts verify FAILS. Uses registry-test. Run by clua-interp.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local CLUA = ROOT .. "\\build\\bin\\clua-interp.exe"
local PKG   = ROOT .. "\\rover\\src\\rover.lua"
local REG   = ROOT .. "\\rover\\registry-test"
local STORE = (function()
  local h = os.getenv("CLUA_HOME")
  if h and h ~= "" then return h .. "\\packages" end
  return (os.getenv("LOCALAPPDATA") or ".") .. "\\clua\\packages"
end)()

local function run(args)
  local p = io.popen('"' .. CLUA .. ' -i ' .. PKG .. ' ' .. args .. '" 2>&1')
  if not p then return false, "" end
  local out = p:read("*a") or ""
  local ok = p:close()
  return (ok == true) or (ok == 0), out
end
local function strip(s) return (s:gsub("%[%*%].-\n", "")) end
local function fail(m) print("[-] FAIL test-pkgmgr-integrity: " .. m); run("remove mfpkg"); os.exit(1) end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function append(p, s) local f = io.open(p, "ab"); if not f then return false end f:write(s); f:close(); return true end

run("remove mfpkg")

-- 1) install the multi-file package
local ok, out = run('install mfpkg "' .. REG .. '"')
if not ok then fail("install mfpkg (" .. strip(out) .. ")") end
if not strip(out):match("tree sha256") then fail("install did not report a tree hash") end

-- 2) verify passes on a clean install (tree root matches)
ok, out = run("verify mfpkg")
if not ok or not strip(out):match("OK") then fail("verify should pass on a clean multi-file install (" .. strip(out) .. ")") end

-- 3) sanity: helper.lua exists and is a NON-entry-point file
if not slurp(STORE .. "\\mfpkg\\helper.lua") then fail("helper.lua missing from the install") end

-- 4) tamper ONLY helper.lua (init.lua untouched) in BOTH the flat and the
--    versioned store dirs -> the init.lua-only hash would still pass, but the
--    whole-tree root must change and verify must FAIL.
if not append(STORE .. "\\mfpkg\\helper.lua", "\n-- tampered\n") then fail("could not tamper flat helper.lua") end
append(STORE .. "\\mfpkg\\1.0.0\\helper.lua", "\n-- tampered\n")

ok, out = run("verify mfpkg")
if ok then fail("verify should FAIL after a non-init file was swapped, but it passed") end
if not strip(out):match("INTEGRITY FAILURE") then fail("verify did not report INTEGRITY FAILURE for the helper tamper") end

-- 5) reinstall recovers integrity
ok = run('install mfpkg "' .. REG .. '"')
if not ok then fail("reinstall mfpkg after tamper") end
ok, out = run("verify mfpkg")
if not ok or not strip(out):match("OK") then fail("verify should pass again after reinstall") end

run("remove mfpkg")
print("[+] PASS test-pkgmgr-integrity (whole-tree Merkle root: swapped helper.lua detected by verify)")
os.exit(0)
