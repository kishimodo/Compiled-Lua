-- Polish test (Feature 6): caret semver on 0.x (^0.2.3 pins the MINOR when
-- major==0, per node-semver), prerelease handling, `remove` dropping the entry
-- from BOTH luavm.toml and luavm.lock, the `--registry` flag, and `publish`
-- index.json generation. Pure-logic checks use the $LUAVM_PKG_TEST export hook;
-- end-to-end checks use registry-test. Run from the repo root by luavm.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local LUAVM = ROOT .. "\\build\\bin\\luavm.exe"
local PKG   = ROOT .. "\\package-manager\\src\\luavm-pkg.lua"
local REG   = ROOT .. "\\package-manager\\registry-test"
local PROJ  = (os.getenv("TEMP") or ".") .. "\\luavm-semvertest"

local function sh(c) local ok, _, code = os.execute('"' .. c .. '"'); return (ok == true) or (ok == 0) or (code == 0) end
local function pk(a) local ok, _, c = os.execute('cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i "' .. PKG .. '" ' .. a); return (ok == true) or (ok == 0) or (c == 0) end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function cleanup() for _, n in ipairs({ "leaf", "mid", "app" }) do sh(LUAVM .. ' -i ' .. PKG .. ' remove ' .. n .. ' >nul 2>&1') end end
local function fail(m) print("[-] FAIL test-pkgmgr-semver: " .. m); cleanup(); os.exit(1) end

----------------------------------------------------------------------
-- A) Pure semver logic via the test-export hook.
----------------------------------------------------------------------
do
  local driver = (os.getenv("TEMP") or ".") .. "\\luavm-semverdriver.lua"
  spit(driver, [[
dofile("package-manager/src/luavm-pkg.lua")
local M = _G.LUAVM_PKG
local function eq(got, want, label)
  if got ~= want then print("FAILCASE:"..label.." got="..tostring(got).." want="..tostring(want)); os.exit(7) end
end
-- caret on >=1.x: standard major lock
eq(M.semver_satisfies("1.9.0", "^1.2.3"), true,  "^1.2.3<-1.9.0")
eq(M.semver_satisfies("2.0.0", "^1.2.3"), false, "^1.2.3<-2.0.0")
-- caret on 0.x: pin the MINOR (node-semver)
eq(M.semver_satisfies("0.2.3", "^0.2.3"), true,  "^0.2.3<-0.2.3")
eq(M.semver_satisfies("0.2.9", "^0.2.3"), true,  "^0.2.3<-0.2.9")
eq(M.semver_satisfies("0.3.0", "^0.2.3"), false, "^0.2.3<-0.3.0")
-- caret on 0.0.x: pin the PATCH
eq(M.semver_satisfies("0.0.3", "^0.0.3"), true,  "^0.0.3<-0.0.3")
eq(M.semver_satisfies("0.0.4", "^0.0.3"), false, "^0.0.3<-0.0.4")
-- prerelease: excluded by a bare * and by a non-prerelease range on a diff tuple
eq(M.semver_satisfies("1.0.0-beta", "*"),       false, "*<-1.0.0-beta")
eq(M.semver_satisfies("1.0.0",      "*"),       true,  "*<-1.0.0")
eq(M.semver_satisfies("1.0.0-beta", "^2.0.0"),  false, "^2<-1.0.0-beta")
-- prerelease ordering and same-tuple range matching
eq(M.semver_satisfies("1.0.0-beta.2", ">=1.0.0-beta.1"), true,  "ge-beta.1<-beta.2")
eq(M.semver_satisfies("1.0.0-beta.1", ">=1.0.0-beta.2"), false, "ge-beta.2<-beta.1")
eq(M.semver_cmp(M.parse_semver("1.0.0-alpha"), M.parse_semver("1.0.0")) < 0, true, "alpha<release")
-- tilde: ~1 (major only) means >=1.0.0 <2.0.0 (regressed: required minor==0)
eq(M.semver_satisfies("1.1.0", "~1"),   true,  "~1<-1.1.0")
eq(M.semver_satisfies("1.0.5", "~1"),   true,  "~1<-1.0.5")
eq(M.semver_satisfies("2.0.0", "~1"),   false, "~1<-2.0.0")
eq(M.semver_satisfies("1.2.9", "~1.2"), true,  "~1.2<-1.2.9")
eq(M.semver_satisfies("1.3.0", "~1.2"), false, "~1.2<-1.3.0")
-- compound AND comparator range (the single most common two-sided syntax)
eq(M.semver_satisfies("1.5.0", ">=1.0.0 <2.0.0"), true,  "compound<-1.5.0")
eq(M.semver_satisfies("2.0.0", ">=1.0.0 <2.0.0"), false, "compound<-2.0.0")
eq(M.semver_satisfies("0.9.0", ">=1.0.0 <2.0.0"), false, "compound<-0.9.0")
eq(M.semver_satisfies("1.5.0", ">= 1.2.0"),       true,  "space-after-op<-1.5.0")
-- x-ranges
eq(M.semver_satisfies("1.5.0", "1.x"),   true,  "1.x<-1.5.0")
eq(M.semver_satisfies("2.0.0", "1.x"),   false, "1.x<-2.0.0")
eq(M.semver_satisfies("1.2.9", "1.2.x"), true,  "1.2.x<-1.2.9")
eq(M.semver_satisfies("1.5.0", "1.*"),   true,  "1.*<-1.5.0")
eq(M.semver_satisfies("1.5.0", "1"),     true,  "1<-1.5.0")
eq(M.semver_satisfies("3.1.0", "x"),     true,  "x<-3.1.0")
-- hyphen ranges
eq(M.semver_satisfies("1.5.0", "1.0.0 - 2.0.0"), true,  "hyphen<-1.5.0")
eq(M.semver_satisfies("2.0.1", "1.0.0 - 2.0.0"), false, "hyphen<-2.0.1")
eq(M.semver_satisfies("2.3.0", "1.2.3 - 2"),     true,  "hyphen-partial<-2.3.0")
eq(M.semver_satisfies("3.0.0", "1.2.3 - 2"),     false, "hyphen-partial<-3.0.0")
-- an unparseable constraint is LOUD (errors), not silently unsatisfiable
do local okp = pcall(M.semver_satisfies, "1.0.0", ">=garbage"); eq(okp, false, "garbage-constraint-errors") end
-- registry shell-injection guard
eq(M.registry_ok("https://example.com/registry"), true,  "registry-ok-url")
eq(M.registry_ok("package-manager\\registry"),    true,  "registry-ok-path")
eq(M.registry_ok('http://x/" & calc & "'),        false, "registry-rejects-quote-amp")
eq(M.registry_ok("a|b"),                          false, "registry-rejects-pipe")
eq(M.registry_ok("a%PATH%b"),                     false, "registry-rejects-percent")
print("SEMVER_OK")
]])
  local p = io.popen('set "LUAVM_PKG_TEST=1" && "' .. LUAVM .. '" -i "' .. driver .. '" 2>&1')
  local out = p and p:read("*a") or ""; if p then p:close() end
  os.remove(driver)
  if not out:match("SEMVER_OK") then fail("semver logic check failed: " .. (out:gsub("%s+", " "))) end
end

----------------------------------------------------------------------
-- B) `publish` generates a usable index.json (versions + hashes + files).
----------------------------------------------------------------------
do
  if not sh('"' .. LUAVM .. '" -i "' .. PKG .. '" publish "' .. REG .. '" >nul 2>&1') then fail("publish") end
  local idx = slurp(REG .. "\\index.json") or ""
  if not idx:match('"leaf"%s*:%s*%[') then fail("published index missing leaf versions") end
  if not idx:match('"hashes"') then fail("published index missing hashes block") end
  if not idx:match('"files"%s*:.-"mfpkg"') then fail("published index missing files list for multi-file mfpkg") end

  -- B2) `publish --push <dir>` distributes the generated registry to another
  -- location (the local-directory transport; the URL transport uses curl PUT).
  local PUSH = (os.getenv("TEMP") or ".") .. "\\luavm-pushtest"
  sh('rmdir /S /Q "' .. PUSH .. '" >nul 2>&1')
  if not sh('"' .. LUAVM .. '" -i "' .. PKG .. '" publish "' .. REG .. '" --push "' .. PUSH .. '" >nul 2>&1') then
    fail("publish --push to a local directory")
  end
  if not slurp(PUSH .. "\\index.json") then fail("publish --push did not copy index.json to the destination") end
  if not slurp(PUSH .. "\\leaf\\index.json") and not slurp(PUSH .. "\\leaf\\1.0.0\\init.lua")
     and not slurp(PUSH .. "\\leaf\\init.lua") then
    fail("publish --push did not copy any leaf package file")
  end
  sh('rmdir /S /Q "' .. PUSH .. '" >nul 2>&1')
end

----------------------------------------------------------------------
-- C) `--registry` flag works for project install (overrides positional/env).
----------------------------------------------------------------------
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1'); sh('mkdir "' .. PROJ .. '" >nul 2>&1')
cleanup()
spit(PROJ .. "\\luavm.toml", '[dependencies]\nleaf = "^1.0.0"\n')
if not pk('install --registry "' .. REG .. '" >nul 2>&1') then fail("install with --registry flag") end
local lock = slurp(PROJ .. "\\luavm.lock") or ""
if not lock:match('%["leaf"%].-version%s*=%s*"1%.0%.0"') then fail("--registry install did not lock leaf 1.0.0") end

----------------------------------------------------------------------
-- D) `remove` drops the dependency from BOTH luavm.toml AND luavm.lock.
----------------------------------------------------------------------
-- add a second dep so the toml/lock are non-trivial
if not pk('add mid "' .. REG .. '" >nul 2>&1') then fail("add mid for remove test") end
if not pk('remove leaf >nul 2>&1') then fail("remove leaf") end
local toml2 = slurp(PROJ .. "\\luavm.toml") or ""
local lock2 = slurp(PROJ .. "\\luavm.lock") or ""
if toml2:match("\n%s*leaf%s*=") then fail("remove did not drop leaf from luavm.toml") end
-- check the TOP-LEVEL lock entry (`["leaf"] = {`) is gone -- note that mid's
-- `deps = { ["leaf"] = ... }` edge legitimately still mentions leaf as a name.
if lock2:match('%["leaf"%]%s*=%s*{%s*version') then fail("remove did not drop the leaf entry from luavm.lock") end
-- mid must still be present (remove only targets the named package)
if not lock2:match('%["mid"%]%s*=%s*{%s*version') then fail("remove leaf should not have removed mid from the lock") end

cleanup()
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1')
print("[+] PASS test-pkgmgr-semver (caret 0.x + prerelease; publish; --registry; remove drops toml+lock)")
os.exit(0)
