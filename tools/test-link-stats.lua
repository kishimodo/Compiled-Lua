-- tools/test-link-stats.lua : the internal linker's CLUA_GC_DEBUG accounting.
--
-- Auto-discovered by tools/run-tests.lua (phase 6). Two properties matter, and
-- the second one is the reason this file exists rather than an eyeballed run:
--
--   1. the [ar] archive-resolution report is internally consistent -- every
--      query is either answered or missed, and every answered query costs
--      exactly one member lookup -- so the numbers can be trusted to size
--      linker work;
--   2. the instrumentation is INERT: the executable emitted with CLUA_GC_DEBUG
--      set is byte-identical to the one emitted without it, and nothing is
--      printed when the variable is unset.
--
-- Property 2 is the one that protects the project invariant. A counter that
-- perturbs resolution order would change which archive member gets pulled, and
-- that changes output bytes. See docs/benchmarks/archive-symbol-lookup.md.

local NAME = "test-link-stats"
local failures = {}

local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

-- Windows cmd /c quote trap: when a command STARTS with a quoted path, cmd
-- strips the first and last quote of the whole string, mangling
-- `"a.exe" build "b.lua"` into `a.exe" build "b.lua`. Wrapping the entire
-- command in one more quote pair makes cmd strip THOSE instead, leaving the
-- inner quotes intact. Same trick as tools/run-tests.lua.
local function sh(cmd)
  local p = io.popen('"' .. cmd .. ' 2>&1"')
  if not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  return out
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local ROOT = trim(sh("git rev-parse --show-toplevel")):gsub("/", "\\")
if ROOT == "" then ROOT = trim(sh("cd")) end
local CLUA = ROOT .. "\\build\\bin\\clua.exe"
local TMP  = (os.getenv("TEMP") or ".") .. "\\clua-linkstats-" .. tostring(os.time())

local function spit(path, text)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(text); f:close(); return true
end

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

if not slurp(CLUA) then
  print("[~] SKIP " .. NAME .. " (build\\bin\\clua.exe not built)")
  os.exit(0)
end

os.execute('mkdir "' .. TMP .. '" >nul 2>nul')
local SRC = TMP .. "\\probe.lua"
if not spit(SRC, 'local t = {}\nfor i = 1, 3 do t[i] = i * 2 end\nprint(t[1] + t[2] + t[3])\n') then
  print("[-] FAIL " .. NAME .. ": cannot write " .. SRC)
  os.exit(1)
end

-- ---- build twice: quiet, then instrumented -------------------------------

local QUIET = TMP .. "\\quiet.exe"
local DEBUG = TMP .. "\\debug.exe"

local quiet_out = sh('"' .. CLUA .. '" build "' .. SRC .. '" -O1 -o "' .. QUIET .. '"')
local debug_out = sh('set "CLUA_GC_DEBUG=1" && "' .. CLUA .. '" build "' .. SRC
                     .. '" -O1 -o "' .. DEBUG .. '"')

local quiet_bytes = slurp(QUIET)
local debug_bytes = slurp(DEBUG)

if not quiet_bytes then fail("quiet build produced no executable: %s", quiet_out) end
if not debug_bytes then fail("instrumented build produced no executable: %s", debug_out) end

-- Property 2a: the diagnostic must not change a single output byte.
if quiet_bytes and debug_bytes and quiet_bytes ~= debug_bytes then
  fail("CLUA_GC_DEBUG changed the emitted executable (%d vs %d bytes) -- the "
       .. "instrumentation is perturbing link decisions",
       #quiet_bytes, #debug_bytes)
end

-- Property 2b: silence by default.
if quiet_out:find("%[ar%]") then
  fail("[ar] report printed without CLUA_GC_DEBUG set")
end
if quiet_out:find("%[gc%]") then
  fail("[gc] report printed without CLUA_GC_DEBUG set")
end

-- ---- property 1: the report is present and self-consistent ---------------

local entries, members, rounds =
  debug_out:match("%[ar%] (%d+) archive%(s%), (%d+) armap entries, (%d+) members")
local nrounds = debug_out:match("members, (%d+) fixpoint round%(s%)")
-- A "query" is one (symbol, archive) pair, not one symbol resolution: a single
-- resolution asks several archives in turn. The report says so, and so does
-- this test, because dividing compares by resolutions instead of by queries
-- overstates the per-scan cost by roughly the archive count.
local queries, answered, missed, compares =
  debug_out:match("%[ar%] archive queries (%d+) %((%d+) answered, (%d+) missed%), (%d+) name compares")
local mem_lookups, mem_compares =
  debug_out:match("%[ar%] member lookups (%d+), (%d+) member compares")

if not queries then
  fail("no parsable [ar] archive-query line; got: %s", (debug_out:gsub("\n", " | ")))
else
  entries      = tonumber(entries)
  members      = tonumber(members)
  nrounds      = tonumber(nrounds)
  queries      = tonumber(queries)
  answered     = tonumber(answered)
  missed       = tonumber(missed)
  compares     = tonumber(compares)
  mem_lookups  = tonumber(mem_lookups)
  mem_compares = tonumber(mem_compares)

  if answered + missed ~= queries then
    fail("accounting broken: %d answered + %d missed ~= %d queries",
         answered, missed, queries)
  end
  -- Every armap NAME match performs exactly one member lookup, and nothing else
  -- in the tree calls LcAr_MemberByHdrOff. A match whose entry names no real
  -- member resolves to NULL and is not "answered", so member lookups can exceed
  -- answered queries only on a malformed archive -- which the linker warns about
  -- rather than hiding.
  if mem_lookups < answered then
    fail("member lookups (%d) below answered queries (%d): an answered query "
         .. "must have performed one", mem_lookups, answered)
  end
  if debug_out:find("armap entr[a-z]* matched a name but named no member") then
    fail("linker reported a malformed armap entry: %s",
         (debug_out:match("%[ar%] WARNING:[^\n]*") or "?"))
  end
  if nrounds < 1 then fail("fixpoint rounds reported as %d", nrounds) end
  if entries < 1 then fail("armap entries reported as %d", entries) end
  if members < 1 then fail("archive members reported as %d", members) end
  if queries < 1 then fail("no archive queries recorded for a real link") end
  if answered < 1 then
    fail("no symbol resolved from any archive; the link cannot have worked")
  end
  -- Holds whether the armap is scanned linearly or indexed, so replacing the
  -- scan with a hash does not turn this test red.
  if compares < answered then
    fail("name compares (%d) below answered queries (%d): an answered query "
         .. "must have examined at least one entry", compares, answered)
  end
  if answered > 0 and mem_compares < 1 then
    fail("member lookups happened but no member compares were counted")
  end
end

os.execute('rmdir /s /q "' .. TMP .. '" >nul 2>nul')

if #failures > 0 then
  for _, why in ipairs(failures) do
    print(string.format("[-] FAIL %s: %s", NAME, why))
  end
  os.exit(1)
end

print(string.format("[+] PASS %s (report consistent; %d archive queries, "
                    .. "%d name compares, %d rounds; output byte-identical with "
                    .. "and without the diagnostic)",
                    NAME, queries, compares, nrounds))
os.exit(0)
