-- test-print-flags.lua -- behavioural suite for the four --print-<name> flags.
--
-- Each flag prints one line to stdout, exits 0, and never touches the
-- pipeline. Same convention gcc / clang follow (`-print-target-triple`,
-- `-print-search-dirs`, `-print-runtime-dir`).

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-print-flags (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

local ROOT = io.popen("cd"):read("*l")
local CLUA_ABS = ROOT .. "\\" .. CLUA

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. tostring(detail):sub(1, 300)) or ""))
  end
end

local function run(cmd)
  local f = io.popen("(" .. cmd .. ") 2>&1")
  local out = f:read("*a") or ""
  local okc, _, code = f:close()
  if okc == true then code = 0 end
  return code or -1, out
end

-- ---- 1. --print-target-triple prints the fixed x86_64-pc-windows-msvc ----
do
  local code, out = run(('"%s" --print-target-triple'):format(CLUA_ABS))
  ok(code == 0 and out:find("x86_64-pc-windows-msvc", 1, true) ~= nil,
     "--print-target-triple prints x86_64-pc-windows-msvc",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
end

-- ---- 2. --print-search-dirs mentions CLUA_HOME and a packages dir --------
do
  local code, out = run(('"%s" --print-search-dirs'):format(CLUA_ABS))
  ok(code == 0 and out:find("CLUA_HOME", 1, true) ~= nil
                and out:find("packages", 1, true) ~= nil,
     "--print-search-dirs lists CLUA_HOME + packages",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
end

-- ---- 3. --print-runtime-path prints a path ending in runtime-aot.a -------
do
  local code, out = run(('"%s" --print-runtime-path'):format(CLUA_ABS))
  ok(code == 0 and out:find("runtime%-aot%.a") ~= nil,
     "--print-runtime-path names runtime-aot.a",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
end

-- ---- 4. --print-package-path prints a path (or `(not found)`) ------------
do
  local code, out = run(('"%s" --print-package-path'):format(CLUA_ABS))
  ok(code == 0 and out ~= "",
     "--print-package-path prints something",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
end

if fails > 0 then os.exit(1) end
print("[+] PASS test-print-flags (all checks)")
os.exit(0)
