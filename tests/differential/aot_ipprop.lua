-- M2 interprocedural type propagation: once-assigned, non-escaping local
-- closures get parameter entry types (meet over all static call sites) and,
-- when every reachable return yields one proven-type value, call sites taking
-- one result inherit the proof. Everything outside the tracked pattern must
-- stay conservatively unproven AND behaviorally exact.

-- the tracked shape: helper in a hot loop
local function step(x) return x * 3 + 1 end
local s = 0
for i = 1, 1000 do s = s + step(i) end
print(s)                                   -- 1504500

-- float helper
local function half(x) return x * 0.5 end
local fs = 0.0
for i = 1, 100 do fs = fs + half(i + 0.0) end
print(fs)                                  -- 2525.0

-- mixed-type call sites poison the parameter meet (still exact)
local function echo(v) return v end
print(echo(1) + 1, echo(1.5) + 1)          -- 2 2.5

-- conditional returns of two types -> no summary (still exact)
local function pick(n) if n > 0 then return 1 else return 0.5 end end
print(pick(1), pick(-1), pick(1) + pick(-1))  -- 1 0.5 1.5

-- helper that sometimes returns nothing -> no summary
local function maybe(n) if n > 0 then return n end end
print(maybe(3), maybe(-3))                 -- 3 nil

-- escaping closure (stored in a table): unknown call sites, no propagation
local function esc(x) return x + 1 end
local holder = { esc }
print(esc(1), holder[1](10))               -- 2 11

-- reassigned slot: two writers, untracked
local f2 = function(x) return x + 1 end
f2 = function(x) return x + 2 end
print(f2(10))                              -- 12

-- recursive helper (self call site inside; summary stays conservative)
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
print(fact(6))                             -- 720  (fact captured by itself -> untracked; exact)

-- helper called with too few args: missing param is nil (poisons meet; exact)
local function add2(a, b) if b then return a + b end return a end
print(add2(5, 6), add2(7))                 -- 11 7

-- multret consumption (C ~= 2): no proof consumed, exact
local function two() return 1, 2 end
local a, b = two()
print(a, b, select("#", two()))            -- 1 2 2

-- helper result feeding residency: loop accumulator stays proven through calls
local function inc(x) return x + 1 end
local acc = 0
for i = 1, 500 do
  local v = inc(i)
  acc = acc + v * 2
end
print(acc)                                 -- 251500

-- vararg helper: VARARGPREP clobbers entries (no param proofs; exact)
local function vsum(...) local t = 0 for _, v in ipairs({...}) do t = t + v end return t end
print(vsum(1, 2, 3))                       -- 6

-- nested helpers: inner called by outer (outer's site of inner is tracked
-- only if inner's slot isn't captured -- here it IS an upvalue of outer, so
-- untracked; exactness is what matters)
local function inner(x) return x * 2 end
local function outer(x) return inner(x) + 1 end
print(outer(4))                            -- 9

-- tracked helper whose argument is a call result of another tracked helper
local function g1(x) return x + 10 end
local function g2(x) return x * 2 end
print(g1(g2(5)))                           -- 20
print("done")
