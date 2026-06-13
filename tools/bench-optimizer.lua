-- bench-optimizer.lua -- micro-benchmarks for the CLua optimizer.
--
-- NOT a pass/fail test (wall-clock is machine-dependent), so it is not in
-- tools/run-tests.lua. It is the performance-visibility harness: a basket of
-- representative kernels that each isolate one optimizer win, so regressions in
-- the -O1 type-inference elision (the broad win) or the -O3 memory passes show
-- up as a time change while every checksum stays identical (the differential
-- oracle already guarantees the checksums).
--
-- Compile at each level and compare per-kernel times:
--   for L in -O0 -O1 -O2 -O3; do build\bin\aotc.exe $L tools\bench-optimizer.lua -o b$L.exe; done
--   b-O0.exe ; b-O1.exe ; b-O2.exe ; b-O3.exe
-- (or pass an iteration count as arg[1]). Each kernel prints checksum + time;
-- the checksum MUST match across levels. Speedup = O0 time / O1(or O3) time.

local clock = os.clock
local function timeit(name, fn, n)
  local t0 = clock()
  local checksum = fn(n)
  local t1 = clock()
  print(string.format("%-20s n=%-9d checksum=%-22s %.3fs", name, n, tostring(checksum), t1 - t0))
end

-- 1. tight integer loop -- the headline tag-check-elision win.
local function int_loop(n)
  local s = 0
  for i = 1, n do s = s + i * 2 - 1 end
  return s
end

-- 2. float accumulator -- FLT elision + xmm residency.
local function float_loop(n)
  local s = 0.0
  for i = 1, n do s = s + (i * 0.5 + 1.25) end
  return s
end

-- 3. branchy integer kernel -- proofs must survive control-flow joins.
local function branchy(n)
  local acc = 0
  for i = 1, n do
    if (i & 3) == 0 then acc = acc + i
    elseif (i & 1) == 1 then acc = acc - 2
    else acc = acc + 1 end
  end
  return acc
end

-- 4. call-heavy -- interprocedural type propagation across a tracked helper.
local function callheavy(n)
  local function step(x) return x * 3 + 7 end
  local s = 0
  for i = 1, n do s = s + step(i) end
  return s
end

-- 5. recursion (iterative-depth fib via accumulation, bounded) -- call overhead.
local function recur(n)
  local function fib(k)
    if k < 2 then return k end
    return fib(k - 1) + fib(k - 2)
  end
  local s = 0
  for _ = 1, n do s = s + fib(20) end   -- fib(20)=6765
  return s
end

-- 6. table read/write -- the Rt_GetI/Rt_SetI helper path (mostly level-neutral).
local function table_rw(n)
  local t = { 0, 0, 0, 0 }
  for i = 1, n do
    local j = (i & 3) + 1
    t[j] = t[j] + i
  end
  return t[1] + t[2] + t[3] + t[4]
end

-- 7. string building via table.concat -- stdlib-bound (level-neutral baseline).
local function strbuild(n)
  local parts = {}
  for i = 1, n do parts[i] = i end
  return #table.concat(parts, ",")
end

-- 8. scalar-replaceable struct-in-loop -- the -O3 win (per-iteration alloc gone).
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

local N = tonumber(arg and arg[1]) or 5000000
print("CLua optimizer micro-benchmarks (compile at -O0/-O1/-O2/-O3, compare times)")
timeit("int_loop",    int_loop,    N)
timeit("float_loop",  float_loop,  N)
timeit("branchy",     branchy,     N)
timeit("callheavy",   callheavy,   N)
timeit("recursion",   recur,       math.max(1, N // 200000))
timeit("table_rw",    table_rw,    N)
timeit("strbuild",    strbuild,    math.max(1000, N // 50))
timeit("struct_loop", struct_loop, N)
