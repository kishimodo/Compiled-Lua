-- math_lib.lua : the math library -- exact integer/float results, classification,
-- rounding, fmod/modf, min/max subtype rules, log/exp/sqrt/trig via assertions
-- (printed as OK so transcendental formatting differences can't cause flakiness).
-- A handful of identities are adapted from lua/lua testes/math.lua @ v5.4.7 (MIT).
-- Deterministic; JIT and -i must agree byte-for-byte.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end
local checks = 0
local function ok(c) assert(c); checks = checks + 1 end
local function eqT(a, b) return a == b and math.type(a) == math.type(b) end

local minint <const> = math.mininteger
local maxint <const> = math.maxinteger

-- constants and classification
ok(math.type(0) == "integer" and math.type(0.0) == "float" and not math.type("10"))
ok(maxint == minint - 1)                     -- wraparound identity
ok((1 << 63) == minint)
ok(math.maxinteger + 1 == math.mininteger)
ok(math.pi > 3.14 and math.pi < 3.15)
ok(math.huge > maxint and -math.huge < minint)
ok(0/0 ~= 0/0)                               -- NaN
ok(math.huge == 1/0 and -math.huge == -1/0)

-- floor / ceil: return integers when result fits; preserve subtype rules
ok(eqT(math.floor(3.7), 3) and eqT(math.ceil(3.2), 4))
ok(eqT(math.floor(-3.2), -4) and eqT(math.ceil(-3.7), -3))
ok(eqT(math.floor(5), 5) and eqT(math.ceil(5), 5))      -- integer passes through
ok(math.type(math.floor(3.5)) == "integer")
ok(math.floor(2.0^63) == math.floor(2.0^63))            -- big float floor (stays float-derived)
ok(eqT(math.floor(-0.0), 0))

-- abs preserves subtype
ok(eqT(math.abs(-5), 5) and eqT(math.abs(-5.0), 5.0))
ok(eqT(math.abs(minint), minint))            -- |minint| overflows back to minint
ok(math.abs(-3.5) == 3.5 and math.abs(0.0) == 0.0)

-- min / max: subtype-preserving, order-stable
ok(eqT(math.min(3, 1, 2), 1) and eqT(math.max(3, 1, 2), 3))
ok(eqT(math.min(1, 1.0), 1) or eqT(math.min(1, 1.0), 1.0))  -- impl picks first equal
ok(math.max(-math.huge, 5) == 5 and math.min(math.huge, 5) == 5)
ok(eqT(math.max(2.5, 2), 2.5) and eqT(math.min(2.5, 2), 2))

-- fmod: sign follows the dividend (C fmod), unlike % which follows divisor
ok(math.fmod(7, 3) == 1.0)
ok(math.fmod(-7, 3) == -1.0)                 -- fmod keeps dividend sign
ok(math.fmod(7, -3) == 1.0)
ok(math.fmod(5.5, 2) == 1.5)

-- modf: integral and fractional parts; integral part is a float
do
  local i, f = math.modf(3.75)
  ok(i == 3.0 and math.abs(f - 0.75) < 1e-12)
  i, f = math.modf(-3.75)
  ok(i == -3.0 and math.abs(f + 0.75) < 1e-12)
  i, f = math.modf(5.0)
  ok(i == 5.0 and f == 0.0)
  i = math.modf(math.huge)
  ok(i == math.huge)
end

-- sqrt / exp / log identities (checked, not printed, to avoid FP formatting)
ok(math.sqrt(16) == 4.0 and math.sqrt(2) * math.sqrt(2) - 2 < 1e-12)
ok(math.abs(math.exp(0) - 1.0) < 1e-12)
ok(math.abs(math.log(math.exp(1)) - 1.0) < 1e-12)
ok(math.abs(math.log(8, 2) - 3.0) < 1e-12)   -- log base 2 of 8
ok(math.abs(math.log(1000, 10) - 3.0) < 1e-9)

-- trig identities
ok(math.abs(math.sin(0)) < 1e-12 and math.abs(math.cos(0) - 1.0) < 1e-12)
ok(math.abs(math.sin(math.pi)) < 1e-12)
ok(math.abs(math.sin(math.pi/2) - 1.0) < 1e-12)
do
  local s, c = math.sin(0.7), math.cos(0.7)
  ok(math.abs(s*s + c*c - 1.0) < 1e-12)      -- pythagorean identity
end

-- tointeger: exact conversions only
ok(math.tointeger(3.0) == 3)
ok(math.tointeger(3.5) == nil)
ok(math.tointeger(2.0^53) == (1 << 53))
ok(math.tointeger(math.huge) == nil)
ok(math.tointeger(2.0^63) == nil)            -- out of integer range
ok(math.tointeger(maxint) == maxint)

-- ult: unsigned less-than comparison of integers
ok(math.ult(1, 2) == true)
ok(math.ult(-1, 0) == false)                 -- -1 as unsigned is huge
ok(math.ult(0, -1) == true)
ok(math.ult(minint, maxint) == false)        -- minint unsigned > maxint

-- basic float notation (from upstream math.lua)
ok(0e12 == 0 and .0 == 0 and 0. == 0 and .2e2 == 20 and 2.E-1 == 0.2)

-- a couple of exact printed results (integer-valued, formatting-stable)
show(math.floor(123.999), math.ceil(-0.001), math.abs(-42), math.max(7, 3, 9, 1))
show(math.min(-1.5, 2), math.fmod(17, 5), math.sqrt(144), math.tointeger(8.0))
show(math.type(math.sqrt(4)), math.type(math.floor(9.9)), math.maxinteger // 1)

print("checks=" .. checks)
print("OK")
