-- Regression for the M1 type-inference soundness bug found by the adversarial
-- attack (2026-06-10): the dataflow assumed `#x` and bitwise ops always yield an
-- integer, but __len / __band / __bor / __bxor / __bnot / __shl / __shr
-- metamethods can return ANY type. The result was wrongly marked proven-INT,
-- poisoning downstream tag-check elision -> silent miscompile (raw bits treated
-- as integers). Fixed: those ops yield UNKNOWN unless operands are proven
-- primitive integers. Compiled by aotc and byte-diffed vs luavm.exe -i.

-- __len returning a float, then arithmetic on the result
local tf = setmetatable({}, { __len = function() return 3.5 end })
local nf = #tf
print(nf + 1, nf * 2, nf)            -- 4.5  7.0  3.5

-- __len returning a string (arith string-coercion), and a comparison
local ts = setmetatable({}, { __len = function() return "77" end })
local ns = #ts
print(ns + 1, ns == 77, type(ns))    -- 78  false  string

-- __len returning a float, used in a comparison that elides the tag-check
local tc = setmetatable({}, { __len = function() return 2.0 end })
local nc = #tc
print(nc < 5, nc + 0, math.type(nc)) -- true  2.0  float

-- bitwise metamethods returning non-integers, then downstream arithmetic
local ba = setmetatable({}, { __band = function() return 1.5 end })
local rb = ba & 1
print(rb + 1, math.type(rb))         -- 2.5  float

local bo = setmetatable({}, { __bor = function() return "9" end })
local ro = bo | 0
print(ro + 1, type(ro))              -- 10  string

local bn = setmetatable({}, { __bnot = function() return 4.25 end })
local rn = ~bn
print(rn * 2, math.type(rn))         -- 8.5  float

local bs = setmetatable({}, { __shl = function() return 6.5 end })
local rs = bs << 2
print(rs - 1, math.type(rs))         -- 5.5  float

-- upvalue aliasing: an int-proven for-loop var captured by a nested closure that
-- mutates it to a float must NOT keep its integer proof (the closure writes the
-- aliased stack slot via SETUPVAL). Found by the adversarial soundness attack.
for i = 1, 1 do
  local function f() i = 9.5 end
  f()
  print(i + 1, i * 2, math.type(i))   -- 10.5  19.0  float
end
for i = 1, 3 do
  local function bump() i = i + 0.5 end
  bump()
  local w = i + 1                      -- w copies i's (now float) type
  print(i, math.type(i), w, math.type(w))
end
-- captured plain local mutated to a string through the closure
local v = 5
local function setv() v = "12" end
setv()
print(v + 3, type(v))                  -- 15  string

-- positive cases: genuine integer length + bitwise must still optimize correctly
local arr = { 10, 20, 30, 40 }
local L = #arr
print(L, L + 1, L * 2)               -- 4  5  8
local m = 0xF0
print(m & 0x3C, m | 0x0F, m ~ 0xFF, ~m & 0xFF)  -- 48  255  15  15
local acc = 0
for i = 1, #arr do acc = acc + arr[i] end
print(acc)                           -- 100
