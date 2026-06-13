-- R6 end-to-end test: install a package once into the global store, then both
-- compiler.exe (bundle into a standalone exe) and clua-interp.exe -i (require at
-- runtime) must use it -- the "install once, require anywhere" contract. Run
-- by clua-interp.exe. Uses the default store (%LOCALAPPDATA%\clua\packages) and
-- removes the test package afterwards.

local CLUA    = "build\\bin\\clua-interp.exe"
local COMPILER = "build\\bin\\compiler.exe"
local PKG      = "rover\\src\\rover.lua"
local USES     = "rover\\test\\uses_greet.lua"
local EXE      = (os.getenv("TEMP") or ".") .. "\\pkgmgr_uses.exe"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function capture(cmd) local p = io.popen('"' .. cmd .. '" 2>&1'); if not p then return "" end local o = p:read("*a") or ""; p:close(); return o end
local function fail(m) print("[-] FAIL test-pkgmgr: " .. m); sh(CLUA .. ' -i ' .. PKG .. ' remove greet >nul 2>&1'); os.exit(1) end

-- clean any prior copy, then install
sh(CLUA .. ' -i ' .. PKG .. ' remove greet >nul 2>&1')
if not sh(CLUA .. ' -i ' .. PKG .. ' install greet >nul 2>&1') then fail("install greet") end

-- idempotency: a forgotten reinstall must succeed, not corrupt
if not sh(CLUA .. ' -i ' .. PKG .. ' install greet >nul 2>&1') then fail("reinstall (idempotency)") end

-- compiler must resolve + bundle the installed package into a standalone exe
if not sh(COMPILER .. ' -o "' .. EXE .. '" ' .. USES .. ' >nul 2>&1') then fail("compile uses_greet") end
local cout = capture('"' .. EXE .. '"')
if not cout:match("greet ok") then fail("compiled exe missing 'greet ok' (got: " .. cout:gsub("%s+", " ") .. ")") end

-- interpreter must resolve the installed package via package.path
local iout = capture(CLUA .. ' -i ' .. USES)
if not iout:match("greet ok") then fail("interpreter missing 'greet ok' (got: " .. iout:gsub("%s+", " ") .. ")") end

-- cleanup
sh(CLUA .. ' -i ' .. PKG .. ' remove greet >nul 2>&1')

print("[+] PASS test-pkgmgr (install once -> compiler bundles AND interpreter requires)")
os.exit(0)
