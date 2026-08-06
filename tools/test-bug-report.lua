-- test-bug-report.lua -- behavioural suite for `clua bug-report`.
--
-- The subcommand writes a self-contained Markdown file with the toolchain
-- version, target triple, CLUA_* env vars, OS/CWD, and (if available) a
-- git SHA. The file lands at --out=<path> if given, else in the CWD.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-bug-report (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

local ROOT = io.popen("cd"):read("*l")
local TEMP = os.getenv("TEMP") or "."
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

local function readfile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- ---- 1. bug-report --out writes a Markdown file with expected sections ---
do
  local OUT = TEMP .. "\\clua_t_bug.md"
  os.remove(OUT)
  local code, out = run(('"%s" bug-report "--out=%s"'):format(CLUA_ABS, OUT))
  local raw = readfile(OUT) or ""
  ok(code == 0 and raw:find("# clua bug report", 1, true) ~= nil,
     "bug-report writes a Markdown header",
     ("code=%s head=%q out=%q"):format(tostring(code), raw:sub(1, 200), out:sub(1, 200)))
  ok(raw:find("clua version", 1, true) ~= nil,
     "bug-report includes the clua version",
     ("raw=%q"):format(raw:sub(1, 400)))
  ok(raw:find("target triple", 1, true) ~= nil
       and raw:find("x86_64-pc-windows-msvc", 1, true) ~= nil,
     "bug-report includes the target triple",
     ("raw=%q"):format(raw:sub(1, 500)))
  ok(raw:find("cwd", 1, true) ~= nil,
     "bug-report includes the current working directory",
     ("raw=%q"):format(raw:sub(1, 500)))
  ok(raw:find("Environment", 1, true) ~= nil,
     "bug-report has an Environment section",
     ("raw=%q"):format(raw:sub(1, 700)))
  os.remove(OUT)
end

-- ---- 2. bug-report with no --out derives a timestamped default name ------
do
  -- Run from TEMP so the derived clua-bug-report-*.md doesn't clutter the CWD.
  local code, out = run(('cd /D "%s" && "%s" bug-report')
                          :format(TEMP, CLUA_ABS))
  ok(code == 0 and out:find("wrote bug report to", 1, true) ~= nil,
     "bug-report with no --out writes a derived-name file",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 300)))
  -- Best-effort cleanup: sweep any leftover clua-bug-report-*.md in TEMP.
  os.execute(('del /Q "%s\\clua-bug-report-*.md" 2>NUL'):format(TEMP))
end

if fails > 0 then os.exit(1) end
print("[+] PASS test-bug-report (all checks)")
os.exit(0)
