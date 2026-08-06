-- tools/test-object-freshness.lua : no object outlives its source.
--
-- Auto-discovered by tools/run-tests.lua (phase 6). The suite has just built
-- everything, so by the time this runs every object must be strictly newer than
-- the .c it came from. Anything that is not means make declined to rebuild it
-- and the products just linked stale code.
--
-- Companion to test-build-header-deps.lua. That one asserts make KNOWS about
-- header edits; this one asserts make ACTED on source edits. They fail for
-- different reasons and both failures are silent:
--
--   * missing header tracking  -> editing ir.h leaves lift.o stale
--   * equal mtimes             -> editing x64_emit.c leaves x64_emit.o stale
--
-- The second is the one that got us. Make rebuilds only on a STRICTLY newer
-- prerequisite, so a source and object stamped the same whole second look
-- current forever. An A/B in the 2026-07 size arc hit exactly that: it cp'd one
-- arm's source over the other's within the same second, and the pre-imm8 SUB
-- encoder stayed linked through a dozen rebuilds. The wrong rover .text landed
-- in docs/benchmarks/size-and-speed-current.md as a measured figure. Nothing
-- failed; the tree was green throughout. That is the class of bug this gates.
--
-- The real comparison lives in tools/check-object-freshness.py so a human can
-- run it directly mid-A/B, which is when it is most useful.

local NAME = "test-object-freshness"
local failures = {}

local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

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

local CHECKER = "tools\\check-object-freshness.py"

if not io.open(ROOT .. "\\" .. CHECKER, "rb") then
  print(("[~] SKIP %s: %s is missing"):format(NAME, CHECKER))
  os.exit(0)
end

local out = sh("python \"" .. ROOT .. "\\" .. CHECKER .. "\" --json")

-- No python on PATH is a skip, not a failure: the layout gate
-- (test-agent-workspace.lua) already treats python as optional.
if out == "" or out:match("not recognized") or out:match("No such file") then
  print(("[~] SKIP %s: python is unavailable"):format(NAME))
  os.exit(0)
end

local checked = tonumber(out:match('"checked"%s*:%s*(%d+)'))
if not checked then
  fail("could not parse checker output; got: %s", trim(out):sub(1, 300))
elseif checked < 500 then
  -- A near-empty result would make this test vacuous. The tree carries ~617
  -- mapped objects after a full build; a collapse to a handful means the
  -- object layout moved and the mapping in the .py needs updating, which is a
  -- real failure rather than a pass.
  fail("only %d objects were checked (expected ~617) -- the object-tree "
       .. "mapping in %s is out of date and this gate is not covering the build",
       checked, CHECKER)
end

-- Every stale entry, named. The checker prints them as objects of
-- {object, source, lag_seconds}; report each so the fix is obvious.
for object, source, lag in out:gmatch(
    '"object"%s*:%s*"([^"]+)".-"source"%s*:%s*"([^"]+)".-"lag_seconds"%s*:%s*([%-%d%.]+)') do
  fail("%s is not newer than %s (source leads by %ss) -- make will not rebuild "
       .. "it, so the products just linked stale code", object, source, lag)
end

if #failures == 0 then
  print(("[+] PASS %s: all %d objects are strictly newer than their sources")
        :format(NAME, checked or 0))
  os.exit(0)
end

for _, f in ipairs(failures) do
  print(("[-] FAIL %s: %s"):format(NAME, f))
end
print("    Remedy: touch the offending sources and rebuild, or")
print("            make -f build/Makefile clean-objs && cmd /c build\\build-luac.bat")
os.exit(1)
