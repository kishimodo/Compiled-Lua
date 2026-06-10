-- R4.1 automated test: the compiler's -L/--link flag force-bundles a package
-- the static require scan cannot see. Run by luavm.exe (shell-agnostic).
-- Compiles the dynamic-require entry both ways and asserts:
--   without -L  -> produced exe fails at runtime (require not bundled)
--   with -L json -> produced exe succeeds
local COMPILER = "build\\bin\\compiler.exe"   -- backslashes: os.execute -> cmd
local TMP      = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\luavm-fltest"
os.execute('if not exist "' .. TMP .. '" mkdir "' .. TMP .. '" >nul 2>&1')

-- Self-contained entry fixture (written to TMP so the test needs no on-disk
-- tests/ tree): a DYNAMIC require(variable) the compiler's static require-scan
-- cannot see, so 'json' is bundled only when -L forces it.
local ENTRY = TMP .. "\\force_link_entry.lua"
do
  local f = assert(io.open(ENTRY, "wb"))
  f:write('local name = "json"\nprint(require(name).encode({1, 2, 3}))\n')
  f:close()
end

-- Wrap in an outer quote pair so cmd /c does not mangle leading-quoted commands.
local function compile_ok(extra, exe)
  local cmd = COMPILER .. " " .. extra .. '-o "' .. exe .. '" "' .. ENTRY .. '" >nul 2>&1'
  local ok, _, code = os.execute('"' .. cmd .. '"')
  return (ok == true) or (ok == 0) or (code == 0)
end
local function run_exit(exe)
  local _, _, code = os.execute('"' .. '"' .. exe .. '" >nul 2>&1' .. '"')
  return code or -1
end

local nolink   = TMP .. "\\nolink.exe"
local withlink = TMP .. "\\withlink.exe"

if not compile_ok("", nolink) then
  print("[-] FAIL test-force-link (compile without -L failed)"); os.exit(1)
end
if not compile_ok("-L json ", withlink) then
  print("[-] FAIL test-force-link (compile with -L failed)"); os.exit(1)
end

local r_no   = run_exit(nolink)
local r_with = run_exit(withlink)
print(string.format("[*] without -L: exit %s (expect non-zero), with -L json: exit %s (expect 0)",
                    tostring(r_no), tostring(r_with)))

if r_no ~= 0 and r_with == 0 then
  print("[+] PASS test-force-link")
  os.exit(0)
else
  print("[-] FAIL test-force-link (-L did not change bundling as expected)")
  os.exit(1)
end
