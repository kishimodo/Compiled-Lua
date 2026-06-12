-- Project-workflow test: rover.toml (deps) + rover.lock (resolved versions +
-- hashes). Run by luavm.exe from the repo root. Operates in a temp project dir
-- so it never writes rover.toml/rover.lock into the repo. Cleans up afterwards.

-- Absolute repo root: cmd's `cd` with no args prints the current directory.
-- (os.getenv("CD") isn't reliably set when launched by make.) We need an
-- absolute path because the steps below `cd /d` into a temp project dir.
local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close()
  return (d:gsub("%s+$", ""))
end
local CWD     = abscwd()                               -- repo root (absolute)
local LUAVM   = CWD .. "\\build\\bin\\luavm.exe"
local PKG     = CWD .. "\\package-manager\\src\\rover.lua"
local REG     = CWD .. "\\package-manager\\registry"
local PROJ    = (os.getenv("TEMP") or ".") .. "\\luavm-projtest"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
-- run the pkg manager with the project dir as the working directory. The
-- command starts with `cd` (not a quote), so no outer-quote wrap is needed
-- (and wrapping a compound `cd && exe` command would mis-parse under cmd).
local function pk(args)
  local cmd = 'cd /d "' .. PROJ .. '" && "' .. LUAVM .. '" -i "' .. PKG .. '" ' .. args
  local ok, _, c = os.execute(cmd)
  return (ok == true) or (ok == 0) or (c == 0)
end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function fail(m) print("[-] FAIL test-pkgmgr-project: " .. m); sh(LUAVM .. ' -i ' .. PKG .. ' remove greet >nul 2>&1'); os.exit(1) end

sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1')
sh('mkdir "' .. PROJ .. '" >nul 2>&1')
sh(LUAVM .. ' -i ' .. PKG .. ' remove greet >nul 2>&1')

-- 1) add a dependency: installs it AND records rover.toml + rover.lock
if not pk('add greet "' .. REG .. '"') then fail("add greet") end

local toml = slurp(PROJ .. "\\rover.toml")
if not toml then fail("rover.toml not created") end
if not toml:match("%[dependencies%]") or not toml:match("greet%s*=") then fail("rover.toml missing greet dependency") end

local lock = slurp(PROJ .. "\\rover.lock")
if not lock then fail("rover.lock not created") end
if not lock:match('%["greet"%]') or not lock:match('hash%s*=%s*"%x%x%x') then fail("rover.lock missing greet version/hash") end

-- 2) project verify passes on a clean install
if not pk('verify >nul 2>&1') then fail("project verify should pass on clean install") end

-- 3) tamper the installed package -> project verify must FAIL
sh(LUAVM .. ' -i ' .. PKG .. ' where > "' .. PROJ .. '\\store.txt"')
-- read the store path (strip JIT/runtime noise + trailing newline)
local storeRaw = slurp(PROJ .. "\\store.txt") or ""
local store
for line in (storeRaw .. "\n"):gmatch("(.-)\r?\n") do
  if line ~= "" and not line:match("^%[%*%]") then store = line end
end
if not store then fail("could not read store path") end
-- project verify checks the VERSIONED dir the lock pins; tamper that exact file.
local ver = lock:match('%["greet"%]%s*=%s*{[^}]-version%s*=%s*"([^"]+)"')
if not ver then fail("could not read greet version from lock") end
local initp = store .. "\\greet\\" .. ver .. "\\init.lua"
local f = io.open(initp, "ab")
if not f then  -- fall back to the flat path (un-versioned install)
  f = io.open(store .. "\\greet\\init.lua", "ab")
end
if not f then fail("could not open installed greet to tamper") end
f:write("\n-- tamper\n"); f:close()

if pk('verify >nul 2>&1') then fail("project verify should FAIL after tampering an installed dep") end

-- 4) re-installing the dependency recovers integrity; project verify passes again
if not pk('add greet "' .. REG .. '" >nul 2>&1') then fail("reinstall greet via add") end
if not pk('verify >nul 2>&1') then fail("project verify should pass after reinstall") end

-- cleanup
sh(LUAVM .. ' -i ' .. PKG .. ' remove greet >nul 2>&1')
sh('rmdir /S /Q "' .. PROJ .. '" >nul 2>&1')
print("[+] PASS test-pkgmgr-project (rover.toml + rover.lock: add/install/verify + tamper detection)")
os.exit(0)
