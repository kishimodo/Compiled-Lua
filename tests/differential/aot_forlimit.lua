-- Rt_ForPrep limit coercion must mirror lvm.c forlimit(): an integer loop whose
-- FLOAT limit is beyond int64 range TRUNCATES (LUA_MAXINTEGER / LUA_MININTEGER)
-- and RUNS; it skips only when the limit is on the wrong side of the step.
-- (Bug found by the adversarial attack: `for i = 1, math.huge` silently ran
-- zero iterations at every opt level.)

-- +inf limit, counting up: must run (clamped to maxinteger)
local n = 0
for i = 1, math.huge do n = n + 1 if i >= 3 then break end end
print("huge-up", n)                          -- 3

-- -inf limit, counting down: must run
n = 0
for i = 3, -math.huge, -1 do n = n + 1 if i <= 1 then break end end
print("huge-down", n)                        -- 3

-- big finite floats beyond int64: clamp + run
n = 0
for i = 1, 1e300 do n = n + 1 if i >= 2 then break end end
print("1e300", n)                            -- 2
n = 0
for i = 1, 9.3e18 do n = n + 1 if i >= 2 then break end end
print("9.3e18", n)                           -- 2
n = 0
for i = 1, 2^63 do n = n + 1 if i >= 2 then break end end
print("2^63", n)                             -- 2

-- clamped limit actually reaches maxinteger / mininteger exactly
for i = math.maxinteger - 1, 2^63 do print("g", i) end
for i = math.mininteger + 1, -2^63 - 2048, -1 do print("h", i) end

-- wrong-side infinities: zero iterations
n = 0
for i = 1, math.huge, -1 do n = n + 1 break end
for i = 1, -math.huge do n = n + 1 break end
print("wrong-side", n)                       -- 0

-- NaN limit: counting up skips; counting down clamps to mininteger and RUNS
-- (lvm.c forlimit treats NaN like a too-small limit -- mirror it exactly)
local nan = 0 / 0
n = 0
for i = 1, nan do n = n + 1 break end
print("nan-up", n)                           -- 0
n = 0
for i = 1, nan, -1 do n = n + 1 if n >= 2 then break end end
print("nan-down", n)                         -- 2

-- in-range float limits still floor/ceil correctly
local a = {}
for i = 1, 3.5 do a[#a + 1] = i end
print(table.concat(a, ","))                  -- 1,2,3
a = {}
for i = 5, 1.5, -1 do a[#a + 1] = i end
print(table.concat(a, ","))                  -- 5,4,3,2

-- non-numeric limits: same catchable error, and string limits behave like the
-- interpreter (whatever it does -- the diff is the arbiter)
print(pcall(function() local s = 0 for i = 1, "3" do s = s + i end return s end))
print(pcall(function() for i = 1, {} do end end))
print(pcall(function() for i = 1, "x" do end end))
