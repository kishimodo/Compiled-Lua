-- Remote-registry trust test (Feature 5). index.json carries per-version
-- sha256 (the whole-tree root from Feature 3); downloaded content is verified
-- against it BEFORE install, and a tampered download is rejected. Also tests the
-- optional detached signature: with $ROVER_REGISTRY_KEY set, the manager fetches
-- index.json.sig and verifies HMAC-SHA256(index.json, key); a missing/bad
-- signature is rejected. file:// keeps working throughout. Uses registry-test
-- via a file:// URL. Run from the repo root by clua-interp.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local CLUA = ROOT .. "\\build\\bin\\clua-interp.exe"
local PKG   = ROOT .. "\\rover\\src\\rover.lua"
local REGD  = ROOT .. "\\rover\\registry-test"
local URL   = "file:///" .. ROOT:gsub("\\", "/") .. "/rover/registry-test"
local REGINIT = REGD .. "\\leaf\\1.0.0\\init.lua"
local SIGP    = REGD .. "\\index.json.sig"
local PROJ  = (os.getenv("TEMP") or ".") .. "\\clua-interp-trusttest"

local function sh(c) local ok, _, code = os.execute('"' .. c .. '"'); return (ok == true) or (ok == 0) or (code == 0) end
-- run the manager in PROJ with an explicit child environment override (env). The
-- `set` in the same cmd line scopes the var to that child only.
local function pk_env(env, a)
  local pre = env and ('set "' .. env .. '" && ') or ""
  local ok, _, c = os.execute('cd /d "' .. PROJ .. '" && ' .. pre .. '"' .. CLUA .. '" -i "' .. PKG .. '" ' .. a)
  return (ok == true) or (ok == 0) or (c == 0)
end
local function pk(a) return pk_env(nil, a) end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function fail(m) print("[-] FAIL test-pkgmgr-trust: " .. m); sh(CLUA .. ' -i ' .. PKG .. ' remove leaf >nul 2>&1'); os.remove(SIGP); os.exit(1) end

sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1'); sh('mkdir "' .. PROJ .. '" >nul 2>&1')
sh(CLUA .. ' -i ' .. PKG .. ' remove leaf >nul 2>&1')
os.remove(SIGP)   -- start without a signature (trust-by-hash only)

-- 0) make sure the index has hashes (regenerate via publish, no key set).
if not sh('"' .. CLUA .. '" -i "' .. PKG .. '" publish "' .. REGD .. '" >nul 2>&1') then fail("publish index") end
local idx = slurp(REGD .. "\\index.json") or ""
if not idx:match('"hashes"') then fail("published index missing hashes block") end

-- 1) clean remote add verifies against the index hash and installs.
if not pk('add leaf "' .. URL .. '" "1.0.0" >nul 2>&1') then fail("clean remote add should succeed") end
sh(CLUA .. ' -i ' .. PKG .. ' remove leaf >nul 2>&1')

-- 2) TAMPER the registry file but leave the index hash unchanged -> the download
--    no longer matches the trusted hash -> install must be REJECTED.
local orig = slurp(REGINIT)
if not orig then fail("could not read leaf init.lua to tamper") end
spit(REGINIT, orig .. "\n-- injected payload\n")
local tampered_ok = pk('add leaf "' .. URL .. '" "1.0.0" >nul 2>&1')
spit(REGINIT, orig)   -- restore immediately
if tampered_ok then fail("tampered download should be REJECTED by the integrity check, but it installed") end
sh(CLUA .. ' -i ' .. PKG .. ' remove leaf >nul 2>&1')

-- 3) SIGNATURE: publish WITH a key -> writes index.json.sig; with the same key
--    configured, a remote add verifies the signature and succeeds.
local KEY = "test-secret-key-123"
if not sh('set "ROVER_REGISTRY_KEY=' .. KEY .. '" && "' .. CLUA .. '" -i "' .. PKG .. '" publish "' .. REGD .. '" >nul 2>&1') then
  fail("publish with key")
end
if not slurp(SIGP) then fail("publish did not write index.json.sig when a key was set") end
if not pk_env('ROVER_REGISTRY_KEY=' .. KEY, 'add leaf "' .. URL .. '" "1.0.0" >nul 2>&1') then
  fail("signed add with the correct key should succeed")
end
sh(CLUA .. ' -i ' .. PKG .. ' remove leaf >nul 2>&1')

-- 4) a WRONG key must reject (signature mismatch).
if pk_env('ROVER_REGISTRY_KEY=wrong-key', 'add leaf "' .. URL .. '" "1.0.0" >nul 2>&1') then
  fail("add with the wrong signing key should be rejected")
end

-- 5) a MISSING signature with a key configured must reject.
os.remove(SIGP)
if pk_env('ROVER_REGISTRY_KEY=' .. KEY, 'add leaf "' .. URL .. '" "1.0.0" >nul 2>&1') then
  fail("add should reject when a key is set but index.json.sig is absent")
end

-- cleanup: regenerate a clean (unsigned) index so other suites see plain data.
sh(CLUA .. ' -i ' .. PKG .. ' remove leaf >nul 2>&1')
os.remove(SIGP)
sh('"' .. CLUA .. '" -i "' .. PKG .. '" publish "' .. REGD .. '" >nul 2>&1')
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1')
print("[+] PASS test-pkgmgr-trust (index-hash verifies downloads; tamper rejected; HMAC signature enforced)")
os.exit(0)
