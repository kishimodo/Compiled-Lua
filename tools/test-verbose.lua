-- test-verbose.lua -- `clua build -v` / `--verbose` per-phase wall-clock output.
--
-- The verbose flag is meant to be zero-overhead when unset: the driver only
-- reads QueryPerformanceCounter behind the `opt->verbose` guard, and prints
-- the summary block in one flush to stderr AFTER the build so it never
-- interleaves with the normal `[+]` banner on stdout.
--
-- This suite proves the observable half of that contract:
--   * with `-v` the summary appears on stderr (via 2>&1 capture) and
--     contains the five phase markers plus the total: line
--   * with `--verbose` the same summary appears (spelling parity)
--   * without either flag the markers are ABSENT -- a normal build must
--     not accidentally leak timing lines
--
-- Skips cleanly when clua.exe has not been built, so the suite runs in a
-- tree that only has sources.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-verbose (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

local ROOT     = io.popen("cd"):read("*l")
local TEMP     = os.getenv("TEMP") or "."
local CLUA_ABS = ROOT .. "\\" .. CLUA

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. detail:sub(1, 300)) or ""))
  end
end

-- Capture stdout+stderr; the verbose summary lands on stderr, the [+] build
-- banner on stdout, so 2>&1 is the simplest way to see both.
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

-- Small self-contained fixture: one main chunk, one nested function so
-- codegen's function count is >= 2 and the (N functions) message reads
-- naturally either way. No requires -> resolve is one module, zero packages.
local FIXTURE = TEMP .. "\\clua_t_verbose.lua"
local EXE     = TEMP .. "\\clua_t_verbose.exe"
writefile(FIXTURE, 'local function greet(w) return "hi " .. w end\nprint(greet("world"))\n')

-- ---- 1. -v prints the summary on stderr ----
do
  os.remove(EXE)
  local code, out = run(('"%s" build "%s" -o "%s" -v'):format(CLUA_ABS, FIXTURE, EXE))
  local has_resolve  = out:find("[resolve]",  1, true) ~= nil
  local has_lift     = out:find("[lift]",     1, true) ~= nil
  local has_optimize = out:find("[optimize]", 1, true) ~= nil
  local has_codegen  = out:find("[codegen]",  1, true) ~= nil
  local has_link     = out:find("[link]",     1, true) ~= nil
  local has_total    = out:find("total:",     1, true) ~= nil
  ok(code == 0 and has_resolve and has_lift and has_optimize and has_codegen
       and has_link and has_total,
     "-v prints [resolve]/[lift]/[optimize]/[codegen]/[link]/total: markers",
     ("code=%s out=%q"):format(tostring(code), out))
end

-- ---- 2. --verbose is a spelling-equivalent alias ----
do
  os.remove(EXE)
  local code, out = run(('"%s" build "%s" -o "%s" --verbose'):format(CLUA_ABS, FIXTURE, EXE))
  ok(code == 0
       and out:find("[resolve]", 1, true)
       and out:find("[codegen]", 1, true)
       and out:find("[link]",    1, true)
       and out:find("total:",    1, true),
     "--verbose is a spelling-equivalent alias of -v",
     ("code=%s out=%q"):format(tostring(code), out))
end

-- ---- 3. without the flag the summary does NOT appear ----
do
  os.remove(EXE)
  local code, out = run(('"%s" build "%s" -o "%s"'):format(CLUA_ABS, FIXTURE, EXE))
  local leaked_resolve = out:find("[resolve]", 1, true) ~= nil
  local leaked_codegen = out:find("[codegen]", 1, true) ~= nil
  local leaked_link    = out:find("[link]",    1, true) ~= nil
  local leaked_total   = out:find("total:",    1, true) ~= nil
  ok(code == 0 and not leaked_resolve and not leaked_codegen and not leaked_link
       and not leaked_total,
     "a plain build does not print phase markers or total:",
     ("code=%s out=%q"):format(tostring(code), out))
end

os.remove(EXE)
os.remove(FIXTURE)

if fails > 0 then os.exit(1) end
print("[+] PASS test-verbose (all checks)")
os.exit(0)
