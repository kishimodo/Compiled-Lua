-- Metamethod dispatch fidelity for immediate/K arith and immediate order
-- comparisons. Lua folds `x - 1` into ADDI x,-1 + MMBINI(TM_SUB, +1) and swaps
-- commutative `1 + x` into ADDK/MULK/BANDK with a flip flag; `t < 2.0` encodes
-- the float-ness of the immediate in the LTI C field. The compiled code must
-- dispatch the SAME event, operand order, and operand TYPE the interpreter
-- does (bugs found by the adversarial attack: __add fired for `x - 1`, and
-- __lt received integer 2 for `t < 2.0`).

local function fmt(v)
  if type(v) == "table" then return "T" end
  return string.format("%s(%s)", tostring(v), math.type(v) or type(v))
end

local mt = {}
local function rec(name)
  return function(a, b) print(name, fmt(a), fmt(b)) return 0 end
end
mt.__add  = rec("add");  mt.__sub  = rec("sub");  mt.__mul = rec("mul")
mt.__div  = rec("div");  mt.__mod  = rec("mod");  mt.__pow = rec("pow")
mt.__idiv = rec("idiv")
mt.__band = rec("band"); mt.__bor  = rec("bor");  mt.__bxor = rec("bxor")
mt.__shl  = rec("shl");  mt.__shr  = rec("shr")
local x = setmetatable({}, mt)

-- ADDI forms: event + original operand + order
local _ = x + 1          -- add T 1(integer)
_ = x - 1                -- sub T 1(integer)   (NOT add T -1!)
_ = 1 + x                -- add 1(integer) T   (flipped)
_ = x + 100

-- K forms (int K)
_ = x * 2                -- mul T 2
_ = 2 * x                -- mul 2 T            (flipped)
_ = x / 2                -- div T 2
_ = x % 3                -- mod T 3
_ = x ^ 2                -- pow T 2
_ = x // 3               -- idiv T 3

-- K forms (float K) -- operand must reach the metamethod as a float
_ = x + 1.5              -- add T 1.5(float)
_ = 1.5 + x              -- add 1.5(float) T
_ = x - 2.5              -- sub T 2.5(float)
_ = x * 0.5              -- mul T 0.5(float)
_ = x / 4.0              -- div T 4.0(float)

-- reg-reg with the constant on the left of a non-commutative op
_ = 1 - x                -- sub 1 T
_ = 2 / x                -- div 2 T
_ = 3 % x                -- mod 3 T

-- bitwise K + flips; shifts (regression for the earlier Rt_ShiftI fix)
_ = x & 1                -- band T 1
_ = 1 & x                -- band 1 T
_ = x | 2                -- bor T 2
_ = x ~ 4                -- bxor T 4
_ = 4 ~ x                -- bxor 4 T
_ = x << 2               -- shl T 2
_ = x >> 2               -- shr T 2
_ = 2 << x               -- shl 2 T

-- order comparisons: event, swap, and the float-immediate flag
local omt = {
  __lt = function(a, b) print("lt", fmt(a), fmt(b)) return true end,
  __le = function(a, b) print("le", fmt(a), fmt(b)) return true end,
}
local t = setmetatable({}, omt)
_ = t < 2                -- lt T 2(integer)
_ = t < 2.0              -- lt T 2.0(float)
_ = 2.0 < t              -- lt 2.0(float) T    (GTI swap)
_ = t <= 3.0             -- le T 3.0(float)
_ = 3.0 <= t             -- le 3.0(float) T    (GEI swap)
_ = t > 5                -- lt 5(integer) T
_ = t >= 5.0             -- le 5.0(float) T

-- the -O1 imm fastpath slow arm: same op site sees an int, then a table
local vals = { 7, x }
for i = 1, 2 do
  local v = vals[i]
  print("mixed", tostring(v + 1))
end

-- numbers still compute exactly (no metamethod involved)
print(5 - 1, 5.5 - 1, 2^53)
print("done")
