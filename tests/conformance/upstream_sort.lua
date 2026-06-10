-- upstream_sort.lua : adapted from lua/lua testes/sort.lua @ v5.4.7 (MIT).
-- Made deterministic + self-contained for the JIT-vs-interpreter differential:
--   * dropped checkerror() / os.clock timing / math.random (non-deterministic);
--   * the exhaustive `perm` sort-verifier is kept verbatim (it sorts every
--     permutation of small arrays and asserts the result is ordered);
--   * the large random sort is reproduced with a fixed-seed LCG instead of
--     math.random so both engines see identical input;
--   * a stable checksum + a count are printed so stdout is identical and meaningful.

local unpack = table.unpack
local checks = 0
local function ok(c) assert(c); checks = checks + 1 end

-- unpack edge cases (deterministic subset)
do
  local a = {}
  local lim = 2000
  for i = 1, lim do a[i] = i end
  ok(select(lim, unpack(a)) == lim and select('#', unpack(a)) == lim)
  ok((unpack(a)) == 1)
  local x = {unpack(a)};        ok(#x == lim and x[1] == 1 and x[lim] == lim)
  x = {unpack(a, lim - 2)};     ok(#x == 3 and x[1] == lim - 2 and x[3] == lim)
  x = {unpack(a, 10, 6)};       ok(next(x) == nil)
  local p, q = unpack(a, 10, 10);    ok(p == 10 and q == nil)
  p, q = unpack(a, 10, 11);          ok(p == 10 and q == 11)
  p, q = unpack{1};                  ok(p == 1 and q == nil)
  p, q = unpack({1, 2}, 1, 1);       ok(p == 1 and q == nil)
end

-- pack
do
  local a = table.pack();              ok(a[1] == nil and a.n == 0)
  a = table.pack(table);               ok(a[1] == table and a.n == 1)
  a = table.pack(nil, nil, nil, nil);  ok(a[1] == nil and a.n == 4)
end

-- move semantics (overlapping / backward / new table)
do
  local function eqT(a, b)
    for k, v in pairs(a) do ok(b[k] == v) end
    for k, v in pairs(b) do ok(a[k] == v) end
  end
  eqT(table.move({10,20,30}, 1, 3, 2), {10,10,20,30})       -- forward
  eqT(table.move({10,20,30}, 1, 3, 3), {10,20,10,20,30})    -- forward overlap
  local a = {10,20,30,40}; table.move(a, 1, 4, 2, a); eqT(a, {10,10,20,30,40})
  eqT(table.move({10,20,30}, 2, 3, 1), {20,30,30})          -- backward
  local dst = {}; ok(table.move({10,20,30}, 1, 3, 1, dst) == dst); eqT(dst, {10,20,30})
  dst = {}; ok(table.move({10,20,30}, 1, 0, 3, dst) == dst); eqT(dst, {})  -- empty
end

print "testing sort"

-- check that an array is sorted by f
local function check(a, f)
  f = f or function(x, y) return x < y end
  for n = #a, 2, -1 do ok(not f(a[n], a[n - 1])) end
end

-- months sort lexicographically
do
  local a = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
  table.sort(a)
  check(a)
end

-- exhaustive: sort EVERY permutation of small arrays and verify ordering
local function perm(s, n)
  n = n or #s
  if n == 1 then
    local t = {unpack(s)}
    table.sort(t)
    check(t)
  else
    for i = 1, n do
      s[i], s[n] = s[n], s[i]
      perm(s, n - 1)
      s[i], s[n] = s[n], s[i]
    end
  end
end
perm{}
perm{1}
perm{1,2}
perm{1,2,3}
perm{1,2,3,4}
perm{2,2,3,4}
perm{1,2,3,4,5}
perm{1,2,3,3,5}
perm{1,2,3,4,5,6}
perm{2,2,3,3,5,6}

-- a large, REPRODUCIBLE random sort via a fixed-seed LCG (no math.random)
do
  local seed = 123456789
  local function rnd()
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    return seed
  end
  local n = 4000
  local a = {}
  for i = 1, n do a[i] = rnd() end
  table.sort(a)
  check(a)                                  -- ascending
  -- re-sort an already sorted array (exercises the sorted fast path)
  table.sort(a)
  check(a)
  -- invert-sort with a custom comparator
  table.sort(a, function(x, y) return y < x end)
  check(a, function(x, y) return y < x end)
  -- checksum of the sorted-descending result (engine-independent)
  local sum = 0
  for i = 1, n do sum = (sum + a[i] * i) & 0xffffffffffff end
  print("sort-checksum=" .. sum)
end

-- empty and all-equal arrays
table.sort{}
do
  local a = {}
  for i = 1, 1000 do a[i] = false end
  table.sort(a, function() return false end)
  for _, v in pairs(a) do ok(v == false) end
end

-- sort via a metatable __lt
do
  local tt = {__lt = function(a, b) return a.val < b.val end}
  local seed = 42
  local function rnd() seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % 100 end
  local a = {}
  for i = 1, 10 do a[i] = setmetatable({val = rnd()}, tt) end
  table.sort(a)
  check(a, tt.__lt)
end

print("checks=" .. checks)
print "OK"
