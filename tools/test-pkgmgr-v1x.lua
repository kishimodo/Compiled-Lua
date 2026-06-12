-- v1.x rover test: SHA-256 content integrity. Run by luavm.exe.
-- Installs greet (records a manifest hash), verifies OK, tampers the installed
-- copy and asserts `verify` detects it, then reinstalls and asserts recovery.
-- Uses the default store; cleans up afterwards.

local LUAVM = "build\\bin\\luavm.exe"
local PKG   = "rover\\src\\rover.lua"

local function run(args)  -- returns (ok, combined output)
  local p = io.popen('"' .. LUAVM .. ' -i ' .. PKG .. ' ' .. args .. '" 2>&1')
  if not p then return false, "" end
  local out = p:read("*a") or ""
  local ok = p:close()
  return (ok == true) or (ok == 0), out
end
local function strip(s) return (s:gsub("%[%*%].-\n", "")) end
local function fail(m)
  print("[-] FAIL test-pkgmgr-v1x: " .. m)
  run("remove greet")
  os.exit(1)
end

-- 0) clean slate
run("remove greet")

-- 1) install records a manifest with a version + sha256
local ok, out = run("install greet")
if not ok then fail("install greet (" .. strip(out) .. ")") end
if not strip(out):match("v1%.0%.0") then fail("install did not report version 1.0.0") end
if not strip(out):match("sha256") then fail("install did not report a sha256 hash") end

-- 2) info shows the manifest
ok, out = run("info greet")
if not strip(out):match("version:%s*1%.0%.0") then fail("info missing version") end
if not strip(out):match("sha256:%s*%x%x%x%x") then fail("info missing sha256") end

-- 3) verify passes on a clean install
ok, out = run("verify greet")
if not ok then fail("verify should pass on clean install (" .. strip(out) .. ")") end
if not strip(out):match("OK") then fail("verify did not report OK") end

-- 4) tamper the installed copy -> verify must FAIL (integrity detection)
local _, where = run("where")
local store = strip(where):gsub("%s+$", "")
local initp = store .. "\\greet\\init.lua"
local f = io.open(initp, "ab")
if not f then fail("could not open installed init.lua to tamper") end
f:write("\n-- tampered byte\n"); f:close()

ok, out = run("verify greet")
if ok then fail("verify should FAIL after tampering, but it passed") end
if not strip(out):match("INTEGRITY FAILURE") then fail("verify did not report INTEGRITY FAILURE") end

-- 5) reinstall recovers integrity
ok = run("install greet")
if not ok then fail("reinstall after tamper") end
ok, out = run("verify greet")
if not ok or not strip(out):match("OK") then fail("verify should pass after reinstall") end

-- cleanup
run("remove greet")
print("[+] PASS test-pkgmgr-v1x (sha256 manifest + verify detects tampering)")
os.exit(0)
