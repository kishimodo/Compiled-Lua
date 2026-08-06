-- tools/test-olevel-contract.lua : the -O contract is honest and enforced.
--
-- Auto-discovered by tools/run-tests.lua (phase 6). Three properties:
--
--   1. UNSUPPORTED LEVELS ARE REJECTED. Both drivers used atoi(arg+2), so
--      `-Ofast`, `-Os` and `-Oz` silently became -O0 and `-O9` silently enabled
--      every level. A user asking for a size-optimised build got the faithful
--      boxed baseline and no warning. Rejection must be an error with a nonzero
--      exit, not a note.
--
--   2. SUPPORTED LEVELS STILL WORK, including bare `-O` (== -O1). A strictness
--      change that also broke a real level would be worse than the problem.
--
--   3. -O1 AND -O2 EMIT IDENTICAL BYTES. This is the load-bearing one. The help
--      text now states plainly that -O2 runs nothing -O1 does not, and this
--      assertion is what keeps that statement TRUE rather than merely written
--      down. The day someone implements monomorphize / ip_devirt / dead_global,
--      this test fails -- and the fix is to update the help text and this
--      assertion together, which is exactly the coupling that was missing.

local NAME = "test-olevel-contract"
local failures = {}

local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

-- cmd /c strips the first and last quote of the whole string, so wrap it once
-- more when the command starts with a quoted path (see tools/run-tests.lua).
local function run(cmd)
  local p = io.popen('"' .. cmd .. ' 2>&1"')
  if not p then return -1, "" end
  local out = p:read("*a") or ""
  local ok, _, code = p:close()
  if ok == true then code = 0 end
  return code or -1, out
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local ROOT = trim(select(2, run("git rev-parse --show-toplevel"))):gsub("/", "\\")
if ROOT == "" then ROOT = trim(select(2, run("cd"))) end
local CLUA = ROOT .. "\\build\\bin\\clua.exe"
local AOTC = ROOT .. "\\build\\bin\\aotc.exe"
local TMP  = (os.getenv("TEMP") or ".") .. "\\clua-olevel-" .. tostring(os.time())

local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end; return false
end
local function slurp(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

if not exists(CLUA) or not exists(AOTC) then
  print("[~] SKIP " .. NAME .. " (clua.exe/aotc.exe not built)")
  os.exit(0)
end

os.execute('mkdir "' .. TMP .. '" >nul 2>nul')
local SRC = TMP .. "\\prog.lua"
do
  -- Enough shape to give the -O1 fastpaths and the -O3 scalar-replacement pass
  -- something to chew on, so "identical bytes" is a meaningful claim.
  local f = io.open(SRC, "wb")
  if not f then print("[-] FAIL " .. NAME .. ": cannot write " .. SRC); os.exit(1) end
  f:write('local t = {}\nt.x = 1\nlocal acc = t.x\n'
       .. 'for i = 1, 200 do acc = acc + i * 2 end\n'
       .. 'local function bump(n) acc = acc + n return acc end\n'
       .. 'print(bump(3), acc, ("s"):rep(2))\n')
  f:close()
end

-- ---- 1. unsupported levels are rejected, by BOTH drivers ------------------

for _, lvl in ipairs({ "-Ofast", "-Os", "-Oz", "-O9", "-O4", "-O-1", "-O2x" }) do
  local out = TMP .. "\\rej.exe"
  os.remove(out)
  local code, txt = run('"' .. CLUA .. '" build "' .. SRC .. '" ' .. lvl
                        .. ' -o "' .. out .. '"')
  if code == 0 then
    fail("clua accepted unsupported level %s (exit 0)", lvl)
  elseif not txt:find("unsupported optimization level", 1, true) then
    fail("clua rejected %s without saying why: %s", lvl, trim(txt):sub(1, 90))
  end
  if exists(out) then
    fail("clua produced an executable for the rejected level %s", lvl)
  end

  os.remove(out)
  -- Assert the MESSAGE as well as the exit code. Testing only `code ~= 0` is
  -- fail-open: run() returns -1 when io.popen cannot spawn at all, and -1 would
  -- score a launch failure as a correct rejection -- so this half of the check
  -- would keep passing on a machine where aotc.exe never ran.
  local acode, atxt = run('"' .. AOTC .. '" ' .. lvl .. ' "' .. SRC
                          .. '" -o "' .. out .. '"')
  if acode == 0 then
    fail("aotc accepted unsupported level %s (exit 0)", lvl)
  elseif acode == -1 then
    fail("aotc could not be launched for %s, so its rejection was never "
         .. "actually tested", lvl)
  elseif not atxt:find("unsupported optimization level", 1, true) then
    fail("aotc rejected %s without saying why (exit %s): %s", lvl,
         tostring(acode), trim(atxt):sub(1, 90))
  end
  if exists(out) then
    fail("aotc produced an executable for the rejected level %s", lvl)
  end
end

-- ---- 2. supported levels still work --------------------------------------

local bytes = {}
-- SAME output filename per level: the .rsrc VS_VERSION_INFO block embeds
-- InternalName / OriginalFilename derived from the -o path, so a per-level
-- filename would make identical builds look byte-different. Copy the slurped
-- bytes out before the next compile overwrites the file.
local out = TMP .. "\\ok.exe"
for _, lvl in ipairs({ "-O0", "-O1", "-O2", "-O3", "-O" }) do
  os.remove(out)
  local code, txt = run('"' .. CLUA .. '" build "' .. SRC .. '" ' .. lvl
                        .. ' -o "' .. out .. '"')
  if code ~= 0 then
    fail("clua rejected the supported level %s: %s", lvl, trim(txt):sub(1, 90))
  else
    bytes[lvl] = slurp(out)
    if not bytes[lvl] then fail("no executable produced for %s", lvl) end
  end
end
os.remove(out)

-- bare -O must mean -O1, not "some level"
if bytes["-O"] and bytes["-O1"] and bytes["-O"] ~= bytes["-O1"] then
  fail("bare -O did not compile identically to -O1")
end

-- ---- 3. the honesty tripwire: -O2 emits exactly what -O1 emits -----------

if bytes["-O1"] and bytes["-O2"] then
  if bytes["-O1"] ~= bytes["-O2"] then
    fail("-O1 and -O2 now differ (%d vs %d bytes). That is GOOD NEWS if the M2 "
         .. "passes (monomorphize/ip_devirt/dead_global) were implemented -- "
         .. "update the -O block in clua_main.c's usage() and this assertion "
         .. "together. Otherwise something else changed at -O2.",
         #bytes["-O1"], #bytes["-O2"])
  end
end

-- -O0 must differ from -O1: the typed fastpaths are real, so if these ever
-- match, the -O1 pass group silently stopped running.
if bytes["-O0"] and bytes["-O1"] and bytes["-O0"] == bytes["-O1"] then
  fail("-O0 and -O1 emit identical bytes: the -O1 typed fastpaths are not running")
end

-- -O3 must differ from -O2 ON THIS FIXTURE. The help text calls -O3 "real, but
-- narrow", and the only thing making that true is lc_pass_scalar_replace; the
-- fixture is shaped to give it a table field to promote. Without this check the
-- claim rested on nothing -- if the pass stopped firing, or never fired on this
-- fixture at all, every other assertion here would still pass.
--
-- Deliberately scoped to the fixture, because "narrow" is literal: `clua build
-- rover/src/rover.lua` emits BYTE-IDENTICAL output at -O2 and -O3 (measured
-- 2026-07-26, both 670,720 bytes, same SHA-256). So -O3 has no effect on the
-- largest real program in the tree, and asserting a general -O2 =/= -O3 would be
-- false.
if bytes["-O2"] and bytes["-O3"] and bytes["-O2"] == bytes["-O3"] then
  fail("-O3 emits the same bytes as -O2 on a fixture built to exercise scalar "
       .. "replacement: the -O3 pass group is no longer doing anything, so the "
       .. "help text's \"-O3 (real, but narrow)\" is now false")
end

-- ---- 4. the help text describes what actually happens -------------------

do
  local _, help = run('"' .. CLUA .. '" help')
  for _, phrase in ipairs({ "-O0", "-O1", "-O2", "-O3" }) do
    if not help:find(phrase, 1, true) then
      fail("`clua help` no longer documents %s", phrase)
    end
  end
  -- The specific claim this item exists to make visible.
  if not help:find("SAME BYTES", 1, true) then
    fail("`clua help` no longer states that -O2 emits the same bytes as -O1; "
         .. "if that changed, so should this test")
  end
  if not help:find("-Os", 1, true) then
    fail("`clua help` should say -Os/-Oz do not exist, so the rejection is not "
         .. "a surprise")
  end
end

os.execute('rmdir /s /q "' .. TMP .. '" >nul 2>nul')

if #failures > 0 then
  for _, why in ipairs(failures) do
    print(string.format("[-] FAIL %s: %s", NAME, why))
  end
  os.exit(1)
end

print("[+] PASS " .. NAME .. " (7 unsupported levels rejected by both drivers, "
      .. "5 supported levels build, bare -O == -O1, -O1 == -O2 as documented, "
      .. "-O0 =/= -O1, help text matches)")
os.exit(0)
