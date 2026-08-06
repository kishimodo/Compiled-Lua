-- test-depfile.lua -- behavioural suite for `--emit-depfile=<path>` and `-MD`.
--
-- The depfile lists every module the resolver walked, in make(1) shape:
--   target: dep1 dep2 dep3
-- Consumers plug it into their build system so a change to any dep triggers
-- a rebuild of the target. Populated from RESOLVE_RESULT_T.Modules[].Path,
-- which already knows every module the closed-world scan reached.
--
-- Skips cleanly when clua.exe hasn't been built.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-depfile (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
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
    print("[-] FAIL " .. name .. (detail and (" -- " .. tostring(detail):sub(1, 400)) or ""))
  end
end

local function run(cmd)
  local f = io.popen("(" .. cmd .. ") 2>&1")
  local out = f:read("*a") or ""
  local okc, _, code = f:close()
  if okc == true then code = 0 end
  return code or -1, out
end

local function writefile(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end

local function readfile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Fixture: an entry that requires two sibling modules. All three must
-- appear in the depfile (Modules[0] = entry, Modules[1..] = required).
local DIR    = TEMP .. "\\clua_t_depfile"
os.execute(('rmdir /S /Q "%s" 2>NUL'):format(DIR))
os.execute(('mkdir "%s" 2>NUL'):format(DIR))

local ENTRY = DIR .. "\\main.lua"
local LIB   = DIR .. "\\lib.lua"
local UTIL  = DIR .. "\\util.lua"

writefile(ENTRY, [[
local lib  = require("lib")
local util = require("util")
print(lib.hi(util.who()))
]])

writefile(LIB, [[
local M = {}
function M.hi(x) return "hi " .. x end
return M
]])

writefile(UTIL, [[
local M = {}
function M.who() return "there" end
return M
]])

-- ---- 1. --emit-depfile writes a target + all three modules -----------------
do
  local DEP = DIR .. "\\out.d"
  local EXE = DIR .. "\\out.exe"
  os.remove(DEP)
  os.remove(EXE)
  local code, out = run(('"%s" build "%s" -o "%s" "--emit-depfile=%s"')
                          :format(CLUA_ABS, ENTRY, EXE, DEP))
  local raw = readfile(DEP) or ""
  ok(code == 0 and raw:find("out.exe", 1, true) ~= nil,
     "--emit-depfile writes a rule whose target is the -o path",
     ("code=%s dep=%q out=%q"):format(tostring(code), raw:sub(1, 400), out:sub(1, 200)))
  ok(raw:find("main.lua", 1, true) ~= nil,
     "depfile lists the entry module (main.lua)",
     ("dep=%q"):format(raw))
  ok(raw:find("lib.lua", 1, true) ~= nil,
     "depfile lists the required lib.lua",
     ("dep=%q"):format(raw))
  ok(raw:find("util.lua", 1, true) ~= nil,
     "depfile lists the required util.lua",
     ("dep=%q"):format(raw))
end

-- ---- 2. -MD derives <output-basename>.d beside the exe ---------------------
do
  local EXE = DIR .. "\\hello.exe"
  local DEP = DIR .. "\\hello.d"
  os.remove(DEP)
  os.remove(EXE)
  local code, out = run(('"%s" build "%s" -o "%s" -MD')
                          :format(CLUA_ABS, ENTRY, EXE))
  local raw = readfile(DEP) or ""
  ok(code == 0 and raw ~= "",
     "-MD derives <output-basename>.d beside the exe",
     ("code=%s dep_present=%s out=%q"):format(tostring(code),
        tostring(raw ~= ""), out:sub(1, 200)))
end

-- ---- 3. depfile line shape: `target: dep dep dep\n` -----------------------
do
  local DEP = DIR .. "\\shape.d"
  local EXE = DIR .. "\\shape.exe"
  os.remove(DEP)
  os.remove(EXE)
  local _, _ = run(('"%s" build "%s" -o "%s" "--emit-depfile=%s"')
                     :format(CLUA_ABS, ENTRY, EXE, DEP))
  local raw = readfile(DEP) or ""
  local colon = raw:find(":", 1, true)
  ok(colon ~= nil and raw:sub(-1) == "\n",
     "depfile has the expected `target: deps\\n` shape",
     ("raw=%q"):format(raw))
end

os.execute(('rmdir /S /Q "%s" 2>NUL'):format(DIR))

if fails > 0 then os.exit(1) end
print("[+] PASS test-depfile (all checks)")
os.exit(0)
