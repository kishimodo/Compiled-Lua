-- tools/test-dead-global-prune.lua : `if false then ... end` guards are
-- constant-folded at -O2 and the enclosed nested closures fall out of the
-- whole-program reachability walk, so their Protos' constants no longer ride
-- the exe.
--
-- Auto-discovered by tools/run-tests.lua (phase 6).
--
-- Two halves of one property, and they fail in opposite directions:
--
--   THE FOLD WORKS.  At -O2, lc_pass_fold_dead_branches neutralizes the
--   provably-taken LOADFALSE+TEST+JMP guard around a block that contains an
--   OP_CLOSURE. That drops the IR-level CLOSURE edge, lc_pass_dead_global
--   then marks the enclosed functions as unreachable, codegen emits a
--   returns-zero stub for each, and protoblob emits a stub record (no
--   constants). A string constant used only in the dead body no longer
--   appears in the resulting exe.
--
--   THE FOLD IS SOUND.  Same fixture at -O0 must contain the string (no
--   folding runs) and both -O0 and -O2 must print the same visible output --
--   the fold cannot change program semantics, only what is embedded in the
--   binary.
--
-- Third check: the -O2 exe is strictly smaller than -O0 (dropping the string
-- and the codegen for the dead functions is not free).

local NAME = "test-dead-global-prune"
local CLUA = "build\\bin\\clua.exe"
local TMP  = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\clua-dead-global"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP " .. NAME .. " (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

os.execute('if not exist "' .. TMP .. '" mkdir "' .. TMP .. '" >nul 2>&1')

-- The fixture must be substantial enough that the dead-branch savings cross
-- the PE FileAlignment (0x200). A tiny fixture would shave ~50-100 bytes off
-- .text and .rdata but leave the file size unchanged after alignment. We add
-- several dead helpers with distinct long string constants so the total
-- stripped ProtoBlob bytes reliably exceed 512.
local FIXTURE = [[
local function reachable() return 42 end
if false then
  local function dead1() return "you should not see me 001 -- long-enough-string-to-take-real-space-in-the-blob" end
  local function dead2() return "you should not see me 002 -- long-enough-string-to-take-real-space-in-the-blob" end
  local function dead3() return "you should not see me 003 -- long-enough-string-to-take-real-space-in-the-blob" end
  local function dead4() return "you should not see me 004 -- long-enough-string-to-take-real-space-in-the-blob" end
  local function dead5() return "you should not see me 005 -- long-enough-string-to-take-real-space-in-the-blob" end
  local function dead6() return "you should not see me 006 -- long-enough-string-to-take-real-space-in-the-blob" end
  local function dead7() return "you should not see me 007 -- long-enough-string-to-take-real-space-in-the-blob" end
  local function dead8() return "you should not see me 008 -- long-enough-string-to-take-real-space-in-the-blob" end
  local function driver() return dead1() .. dead2() .. dead3() .. dead4() .. dead5() .. dead6() .. dead7() .. dead8() end
  print(driver())
end
print(reachable())
]]

-- Any of the dead-branch string constants is enough to fail: they only ever
-- live in the ProtoBlob of a dead function.
local PROBE = "you should not see me"

local src = TMP .. "\\fixture.lua"
do
  local f = assert(io.open(src, "wb"))
  f:write(FIXTURE); f:close()
end

local function build(level, out_exe)
  os.remove(out_exe)
  local cmd = CLUA .. ' build "' .. src .. '" ' .. level
             .. ' -o "' .. out_exe .. '" >nul 2>&1'
  os.execute('"' .. cmd .. '"')
  return exists(out_exe)
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

local function run_exe(exe)
  local f = io.popen('"' .. exe .. '" 2>&1')
  local out = f:read("*a") or ""
  f:close()
  return out
end

local failures = {}
local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

local exe_o0 = TMP .. "\\fixture-O0.exe"
local exe_o2 = TMP .. "\\fixture-O2.exe"

if not build("-O0", exe_o0) then
  fail("clua build -O0 produced no exe")
end
if not build("-O2", exe_o2) then
  fail("clua build -O2 produced no exe")
end

if #failures == 0 then
  local data_o0 = read_all(exe_o0)
  local data_o2 = read_all(exe_o2)
  local out_o0  = run_exe(exe_o0)
  local out_o2  = run_exe(exe_o2)

  -- Both exes must print "42" (from reachable()). The fixture has one visible
  -- print; the guarded print is dead in both -O0 and -O2 by Lua semantics.
  if not out_o0:find("42", 1, true) then
    fail("-O0 exe did not print 42 (got %q)", out_o0)
  end
  if not out_o2:find("42", 1, true) then
    fail("-O2 exe did not print 42 (got %q)", out_o2)
  end

  -- -O2 must strip the dead-branch string constant. -O0 must retain it (no
  -- pass runs at -O0, so lc_pass_fold_dead_branches is inert and the dead
  -- functions' constants stay in the ProtoBlob).
  local o0_has = data_o0 and data_o0:find(PROBE, 1, true) ~= nil
  local o2_has = data_o2 and data_o2:find(PROBE, 1, true) ~= nil
  if not o0_has then
    fail("-O0 exe does NOT contain %q -- the fold must not fire at -O0 or "
      .. "the fixture no longer forces the guarded branch through the front "
      .. "end. Check lc_pass_fold_dead_branches is opt_level>=2 only.", PROBE)
  end
  if o2_has then
    fail("-O2 exe still contains %q -- lc_pass_fold_dead_branches did not "
      .. "recognise the LOADFALSE+TEST+JMP guard around OP_CLOSURE, or "
      .. "lc_pass_dead_global did not mark the enclosed function dead, or "
      .. "protoblob_emit's dead-function stub does not strip constants.",
      PROBE)
  end

  -- Ripping out an entire dead branch and its child functions has to make the
  -- exe smaller. This is a coarse gate (a few bytes of savings still count)
  -- but it catches a fold that fires without actually pruning.
  if data_o0 and data_o2 and #data_o2 >= #data_o0 then
    fail("-O2 exe (%d B) is not smaller than -O0 (%d B) -- dead-function "
      .. "codegen stub + protoblob stub must produce a net shrink.",
      #data_o2, #data_o0)
  end
end

if #failures == 0 then
  print("[+] PASS " .. NAME .. ": -O2 folds `if false` guards and prunes "
     .. "enclosed dead functions")
  os.exit(0)
end

for _, f in ipairs(failures) do print("[-] FAIL " .. NAME .. ": " .. f) end
os.exit(1)
