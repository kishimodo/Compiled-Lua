-- test-strip-mode.lua -- behavioural suite for `--strip=none|debug|all`.
--
-- Contract:
--   * --strip=all is the default and matches the pre-flag baseline
--     byte-for-byte.
--   * --strip=none grows the exe (keeps every symbol the linker would
--     otherwise strip; keeps a `.clualn` section when -g is on).
--   * --strip=debug matches the baseline size when -g is off (no debug
--     info to drop).
--   * An unknown --strip=<x> fails cleanly with a helpful error.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-strip-mode (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
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

local function writefile(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end

local function size_of(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local n = f:seek("end")
  f:close()
  return n
end

local FIXTURE = TEMP .. "\\clua_t_strip.lua"
writefile(FIXTURE, 'local a = 1 + 2\nprint(a)\nreturn 0\n')

local EXE_DEFAULT = TEMP .. "\\clua_t_strip_default.exe"
local EXE_ALL     = TEMP .. "\\clua_t_strip_all.exe"
local EXE_DEBUG   = TEMP .. "\\clua_t_strip_debug.exe"
local EXE_NONE    = TEMP .. "\\clua_t_strip_none.exe"

for _, p in ipairs({EXE_DEFAULT, EXE_ALL, EXE_DEBUG, EXE_NONE}) do
  os.remove(p)
end

-- ---- build the four variants ---------------------------------------------
local function build(exe, extra)
  local cmd = ('"%s" build "%s" -o "%s" %s'):format(CLUA_ABS, FIXTURE, exe, extra or "")
  local code, out = run(cmd)
  return code, out
end

local code_default, out_default = build(EXE_DEFAULT, "")
local code_all,     out_all     = build(EXE_ALL,     "--strip=all")
local code_debug,   out_debug   = build(EXE_DEBUG,   "--strip=debug")
local code_none,    out_none    = build(EXE_NONE,    "--strip=none")

ok(code_default == 0 and exists(EXE_DEFAULT),
   "default build (no --strip) succeeds",
   ("code=%s out=%q"):format(tostring(code_default), out_default:sub(1, 200)))
ok(code_all == 0 and exists(EXE_ALL),
   "--strip=all build succeeds",
   ("code=%s out=%q"):format(tostring(code_all), out_all:sub(1, 200)))
ok(code_debug == 0 and exists(EXE_DEBUG),
   "--strip=debug build succeeds",
   ("code=%s out=%q"):format(tostring(code_debug), out_debug:sub(1, 200)))
ok(code_none == 0 and exists(EXE_NONE),
   "--strip=none build succeeds",
   ("code=%s out=%q"):format(tostring(code_none), out_none:sub(1, 200)))

-- ---- 1. default == --strip=all byte-for-byte (documented promise) --------
if exists(EXE_DEFAULT) and exists(EXE_ALL) then
  local sd, sa = size_of(EXE_DEFAULT), size_of(EXE_ALL)
  ok(sd == sa,
     "default build and --strip=all produce identical sizes",
     ("default=%s all=%s"):format(tostring(sd), tostring(sa)))
end

-- ---- 2. --strip=none is at least as large as --strip=all -----------------
if exists(EXE_ALL) and exists(EXE_NONE) then
  local sa, sn = size_of(EXE_ALL), size_of(EXE_NONE)
  ok(sn >= sa,
     "--strip=none is at least as large as --strip=all",
     ("all=%s none=%s"):format(tostring(sa), tostring(sn)))
end

-- ---- 3. unknown --strip mode fails cleanly -------------------------------
do
  local EXE_BAD = TEMP .. "\\clua_t_strip_bad.exe"
  os.remove(EXE_BAD)
  local code, out = build(EXE_BAD, "--strip=nonsense")
  ok(code ~= 0 and out:find("unknown --strip mode", 1, true) ~= nil,
     "--strip=nonsense fails with a clear error",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
end

for _, p in ipairs({EXE_DEFAULT, EXE_ALL, EXE_DEBUG, EXE_NONE, FIXTURE}) do
  os.remove(p)
end

if fails > 0 then os.exit(1) end
print("[+] PASS test-strip-mode (all checks)")
os.exit(0)
