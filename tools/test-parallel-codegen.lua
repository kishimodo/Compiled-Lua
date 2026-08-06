-- tools/test-parallel-codegen.lua : parallel per-function codegen is byte-safe.
--
-- Auto-discovered by tools/run-tests.lua (phase 6). Compiles the same source
-- three times -- once at -j 1 (sequential), once at -j 4, once at -j 8 -- and
-- fails if any pair of outputs differs. A silent race in the codegen worker
-- pool would produce different .text bytes on the run where the race fired
-- and identical bytes on the runs where it did not, so a single failing pair
-- is enough to prove a race and the pass count is a lower bound on
-- "concurrent codegen produced the expected code".
--
-- Why this is the right shape:
--   - Byte identity across job counts is the ONLY property a threaded
--     codegen can violate without also breaking the differential suite.
--     tools/test-codegen-no-globals.lua rules out the mutable-file-scope
--     class of race statically; this rules out the "escaped through the
--     heap" class dynamically.
--   - Three job counts (1, 4, 8), not two: pairs of 1-vs-4 catch sequential
--     vs threaded, 4-vs-8 catches pool-size-dependent races, and comparing
--     against 1 as the anchor gives a clear "which side is wrong" if a
--     future regression drops a byte.
--
-- Skips cleanly when either (a) clua.exe is not built or (b) the rover
-- submodule is not initialised. Rover is used as the fixture because it is
-- the largest reachable-function count in the tree (about 90 functions),
-- which is what makes the pool actually schedule work across threads; a
-- one-function program would collapse to sequential regardless of -j.

local NAME  = "test-parallel-codegen"
local CLUA  = "build\\bin\\clua.exe"
local INPUT = "rover\\src\\rover.lua"
local TMP   = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\clua-parallel-codegen"

local function exists(path)
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end

if not exists(CLUA) then
  print("[~] SKIP " .. NAME .. " (build\\bin\\clua.exe not built)")
  os.exit(0)
end
if not exists(INPUT) then
  print("[~] SKIP " .. NAME .. " (" .. INPUT .. " missing; rover submodule not initialised)")
  os.exit(0)
end

os.execute('if not exist "' .. TMP .. '" mkdir "' .. TMP .. '" >nul 2>&1')

local JOB_COUNTS = { 1, 4, 8 }

-- SAME output filename per -j run: the .rsrc VS_VERSION_INFO
-- (OriginalFilename/InternalName) is derived from -o, so a per-jobs filename
-- would make byte-identical builds look different. compile() slurps the file
-- into a fresh string right after each build; the string outlives the file.
local function compile(jobs)
  local exe = TMP .. "\\rover-out.exe"
  os.remove(exe)
  -- -O1 rather than the clua default -O2 because -O2 today is byte-identical
  -- to -O1 (the level 2 passes are stubs, per docs/plan-0.3.0-beta.2.md), and
  -- -O1 exercises the M1 typed fastpaths that make each function's emitted
  -- code shape richer -- more surface for a race to land somewhere visible.
  local cmd = CLUA .. ' build "' .. INPUT .. '" -O1 -j ' .. jobs
              .. ' -o "' .. exe .. '" >nul 2>&1'
  local ok = os.execute('"' .. cmd .. '"')
  if not ok then return nil, "clua build failed at -j " .. jobs end
  if not exists(exe) then return nil, "no output exe at -j " .. jobs end
  local f = io.open(exe, "rb")
  if not f then return nil, "cannot read " .. exe end
  local data = f:read("*a"); f:close()
  return data, exe
end

local outputs = {}
for _, j in ipairs(JOB_COUNTS) do
  local data, err = compile(j)
  if not data then
    print(("[-] FAIL %s: %s"):format(NAME, err))
    os.exit(1)
  end
  outputs[j] = { data = data, path = err }
end

-- Byte-identity pairs. Any single mismatch is a fail and enough evidence to
-- reject the whole run: we do not attempt to isolate WHICH function differed,
-- because a diff on a PE is more misleading than useful (section offsets shift
-- once any one bytes moves). The failure message points to the offending
-- pair and the byte at which they first differ; that is what a bisecting
-- reader needs to start narrowing.
local function first_diff(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    if a:byte(i) ~= b:byte(i) then return i end
  end
  if #a ~= #b then return n + 1 end
  return nil
end

local failures = {}
for i = 1, #JOB_COUNTS do
  for k = i + 1, #JOB_COUNTS do
    local ji, jk = JOB_COUNTS[i], JOB_COUNTS[k]
    local a, b = outputs[ji].data, outputs[jk].data
    local off = first_diff(a, b)
    if off then
      failures[#failures + 1] = string.format(
        "-j %d (%d bytes) differs from -j %d (%d bytes) at byte %d "
        .. "-- this is a race in the parallel codegen worker pool",
        ji, #a, jk, #b, off)
    end
  end
end

if #failures > 0 then
  for _, f in ipairs(failures) do
    print(("[-] FAIL %s: %s"):format(NAME, f))
  end
  print("    Inputs kept for inspection: " .. TMP)
  os.exit(1)
end

print(("[+] PASS %s: -j 1, -j 4 and -j 8 produced byte-identical exes "
       .. "(%d bytes)"):format(NAME, #outputs[1].data))
os.exit(0)
