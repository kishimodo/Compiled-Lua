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

-- attack round 12 regression: > 64 functions in the module -- the callee
-- index must never alias (a 6-bit stash mapped fn65 onto fn1 and retagged a
-- float return as raw integer bits)
local fs = {}
do
  local function h01() return 0 end local function h02() return 0 end
  local function h03() return 0 end local function h04() return 0 end
  local function h05() return 0 end local function h06() return 0 end
  local function h07() return 0 end local function h08() return 0 end
  fs[1] = h01() + h02() + h03() + h04() + h05() + h06() + h07() + h08()
end
local function q01() return 1 end  local function q02() return 2 end
local function q03() return 3 end  local function q04() return 4 end
local function q05() return 5 end  local function q06() return 6 end
local function q07() return 7 end  local function q08() return 8 end
local function q09() return 9 end  local function q10() return 10 end
local function q11() return 11 end local function q12() return 12 end
local function q13() return 13 end local function q14() return 14 end
local function q15() return 15 end local function q16() return 16 end
local function q17() return 17 end local function q18() return 18 end
local function q19() return 19 end local function q20() return 20 end
local function q21() return 21 end local function q22() return 22 end
local function q23() return 23 end local function q24() return 24 end
local function q25() return 25 end local function q26() return 26 end
local function q27() return 27 end local function q28() return 28 end
local function q29() return 29 end local function q30() return 30 end
local function q31() return 31 end local function q32() return 32 end
local function q33() return 33 end local function q34() return 34 end
local function q35() return 35 end local function q36() return 36 end
local function q37() return 37 end local function q38() return 38 end
local function q39() return 39 end local function q40() return 40 end
local function q41() return 41 end local function q42() return 42 end
local function q43() return 43 end local function q44() return 44 end
local function q45() return 45 end local function q46() return 46 end
local function q47() return 47 end local function q48() return 48 end
local function q49() return 49 end local function q50() return 50 end
local function q51() return 51 end local function q52() return 52 end
local function q53() return 53 end local function q54() return 54 end
local function q55() return 55 end local function q56() return 56 end
local function q57() return 57 end local function q58() return 58 end
local function q59() return 59 end local function q60() return 60 end
local fT1 = nil
local function fT() return 2.5 end
local x = fT()
print(x, math.type(x), x + 1, x * 2)       -- 2.5 float 3.5 5.0
print(q01() + q60(), fs[1])                -- 61 0
print("done2")
