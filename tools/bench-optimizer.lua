-- bench-optimizer.lua -- micro-benchmarks for the CLua optimizer.
--
-- This is NOT a pass/fail test (wall-clock is machine-dependent), so it is not
-- in tools/run-tests.lua. It is the "earn it" measurement for -O3 escape
-- analysis + scalar replacement (and a home for future optimizer benchmarks).
--
-- Run it compiled at two levels and compare the per-scenario times:
--
--   build\bin\aotc.exe -O1 tools\bench-optimizer.lua -o b1.exe
--   build\bin\aotc.exe -O3 tools\bench-optimizer.lua -o b3.exe
--   b1.exe   &   b3.exe
--
-- Each scenario prints its checksum (must match across levels -- the differential
-- oracle already guarantees this) and its time. The scalar-replacement scenarios
-- drop their per-iteration heap allocation at -O3, so they run dramatically
-- faster there while every checksum stays identical.

local function timeit(name, fn, n)
  local t0 = os.clock()
  local checksum = fn(n)
  local t1 = os.clock()
  print(string.format("%-22s n=%-9d checksum=%-20s time=%.3fs", name, n, tostring(checksum), t1 - t0))
end

-- 1. struct-in-loop: a fresh 2-field record each iteration, fields read back.
--    -O3 scalar-replaces `p` (non-escaping, constant keys, batched reads, no GC
--    safepoint in its live range) -> zero heap allocation in the loop.
local function struct_loop(n)
  local acc = 0
  for i = 1, n do
    local p = {}
    p.a = i
    p.b = i
    local a = p.a
    local b = p.b
    acc = acc + a + b
  end
  return acc
end

-- 2. point struct with integer keys (GETI/SETI path).
local function point_loop(n)
  local sum = 0
  for i = 1, n do
    local v = {}
    v[1] = i
    v[2] = i
    v[3] = i
    local x = v[1]
    local y = v[2]
    local z = v[3]
    sum = sum + x + y + z
  end
  return sum
end

-- 3. control: the same arithmetic with NO table at all. This is the floor the
--    scalar-replaced versions approach at -O3.
local function baseline(n)
  local acc = 0
  for i = 1, n do
    local a = i
    local b = i
    acc = acc + a + b
  end
  return acc
end

local N = tonumber(arg and arg[1]) or 20000000
print("CLua optimizer micro-benchmarks (compile at -O1 and -O3, compare times)")
timeit("struct_loop", struct_loop, N)
timeit("point_loop",  point_loop,  N)
timeit("baseline",    baseline,    N)
