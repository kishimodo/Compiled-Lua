-- upstream_bitwise.lua : adapted from lua/lua testes/bitwise.lua @ v5.4.7 (MIT).
-- Made deterministic + self-contained for the JIT-vs-interpreter differential:
--   * removed `require "bwcoercion"` and the string-coercion-via-metamethod cases
--     (they need a C helper library not present here);
--   * removed the `load()` constant-folding block (no os/debug/T deps remain);
--   * replaced silent asserts with a counter, and the trailing `print'OK'` /
--     `print'+'` markers are kept so stdout is identical across engines.
-- The bit32 reference library (pure Lua, from the same file) is kept in full --
-- it densely exercises shifts/rotates/extract/replace and float coercion.

local checks = 0
local function ok(cond) assert(cond); checks = checks + 1 end

local numbits = string.packsize('j') * 8

ok(~0 == -1)
ok((1 << (numbits - 1)) == math.mininteger)

local a, b, c, d
a = 0xFFFFFFFFFFFFFFFF
ok(a == -1 and a & -1 == a and a & 35 == 35)
a = 0xF0F0F0F0F0F0F0F0
ok(a | -1 == -1)
ok(a ~ a == 0 and a ~ 0 == a and a ~ ~a == -1)
ok(a >> 4 == ~a)
a = 0xF0; b = 0xCC; c = 0xAA; d = 0xFD
ok(a | b ~ c & d == 0xF4)

a = 0xF0.0; b = 0xCC.0
ok(a | b == 0xFC)

a = 0xF0000000; b = 0xCC000000;
c = 0xAA000000; d = 0xFD000000
ok(a | b ~ c & d == 0xF4000000)
ok(~~a == a and ~a == -1 ~ a and -d == ~d + 1)

a = a << 32
b = b << 32
c = c << 32
d = d << 32
ok(a | b ~ c & d == 0xF4000000 << 32)
ok(~~a == a and ~a == -1 ~ a and -d == ~d + 1)

ok(-1 >> 1 == (1 << (numbits - 1)) - 1 and 1 << 31 == 0x80000000)
ok(-1 >> (numbits - 1) == 1)
ok(-1 >> numbits == 0 and -1 >> -numbits == 0 and
   -1 << numbits == 0 and -1 << -numbits == 0)

ok(1 >> math.mininteger == 0)
ok(1 >> math.maxinteger == 0)
ok(1 << math.mininteger == 0)
ok(1 << math.maxinteger == 0)
ok((2^30 - 1) << 2^30 == 0)
ok((2^30 - 1) >> 2^30 == 0)
ok(1 >> -3 == 1 << 3 and 1000 >> 5 == 1000 << -5)

print('+')

-- pure-Lua bit32 reference library (from the same upstream file)
local function make_bit32()
  local bit = {}
  function bit.bnot (x) return ~x & 0xFFFFFFFF end
  function bit.band (x, y, z, ...)
    if not z then return ((x or -1) & (y or -1)) & 0xFFFFFFFF
    else
      local arg = {...}; local res = x & y & z
      for i = 1, #arg do res = res & arg[i] end
      return res & 0xFFFFFFFF
    end
  end
  function bit.bor (x, y, z, ...)
    if not z then return ((x or 0) | (y or 0)) & 0xFFFFFFFF
    else
      local arg = {...}; local res = x | y | z
      for i = 1, #arg do res = res | arg[i] end
      return res & 0xFFFFFFFF
    end
  end
  function bit.bxor (x, y, z, ...)
    if not z then return ((x or 0) ~ (y or 0)) & 0xFFFFFFFF
    else
      local arg = {...}; local res = x ~ y ~ z
      for i = 1, #arg do res = res ~ arg[i] end
      return res & 0xFFFFFFFF
    end
  end
  function bit.btest (...) return bit.band(...) ~= 0 end
  function bit.lshift (x, n) return ((x & 0xFFFFFFFF) << n) & 0xFFFFFFFF end
  function bit.rshift (x, n) return ((x & 0xFFFFFFFF) >> n) & 0xFFFFFFFF end
  function bit.arshift (x, n)
    x = x & 0xFFFFFFFF
    if n <= 0 or (x & 0x80000000) == 0 then return (x >> n) & 0xFFFFFFFF
    else return ((x >> n) | ~(0xFFFFFFFF >> n)) & 0xFFFFFFFF end
  end
  function bit.lrotate (x, n)
    n = n & 31; x = x & 0xFFFFFFFF
    x = (x << n) | (x >> (32 - n))
    return x & 0xFFFFFFFF
  end
  function bit.rrotate (x, n) return bit.lrotate(x, -n) end
  local function checkfield (f, w)
    w = w or 1
    assert(f >= 0); assert(w > 0); assert(f + w <= 32)
    return f, ~(-1 << w)
  end
  function bit.extract (x, f, w)
    local ff, mask = checkfield(f, w); return (x >> ff) & mask
  end
  function bit.replace (x, v, f, w)
    local ff, mask = checkfield(f, w)
    v = v & mask
    x = (x & ~(mask << ff)) | (v << ff)
    return x & 0xFFFFFFFF
  end
  return bit
end

local bit32 = make_bit32()

ok(bit32.band() == bit32.bnot(0))
ok(bit32.btest() == true)
ok(bit32.bor() == 0)
ok(bit32.bxor() == 0)
ok(bit32.band() == bit32.band(0xffffffff))
ok(bit32.band(1,2) == 0)

ok(bit32.band(-1) == 0xffffffff)
ok(bit32.band((1 << 33) - 1) == 0xffffffff)
ok(bit32.band((1 << 33) + 1) == 1)
ok(bit32.band(-(1 << 40)) == 0)

ok(bit32.lrotate(0x12345678, 0) == 0x12345678)
ok(bit32.lrotate(0x12345678, 32) == 0x12345678)
ok(bit32.lrotate(0x12345678, 4) == 0x23456781)
ok(bit32.rrotate(0x12345678, -4) == 0x23456781)
ok(bit32.lrotate(0x12345678, -8) == 0x78123456)
ok(bit32.rrotate(0x12345678, 8) == 0x78123456)
ok(bit32.lrotate(0xaaaaaaaa, 2) == 0xaaaaaaaa)
for i = -50, 50 do
  ok(bit32.lrotate(0x89abcdef, i) == bit32.lrotate(0x89abcdef, i % 32))
end

ok(bit32.lshift(0x12345678, 4) == 0x23456780)
ok(bit32.lshift(0x12345678, -4) == 0x01234567)
ok(bit32.lshift(0x12345678, 32) == 0)
ok(bit32.rshift(0x12345678, 4) == 0x01234567)
ok(bit32.rshift(0x12345678, 32) == 0)
ok(bit32.arshift(0x12345678, 1) == 0x12345678 // 2)
ok(bit32.arshift(0x12345678, -1) == 0x12345678 * 2)
ok(bit32.arshift(-1, 1) == 0xffffffff)
ok(bit32.arshift(-1, 32) == 0xffffffff)

ok(0x12345678 << 4 == 0x123456780)
ok(0x12345678 << 32 == 0x1234567800000000)
ok(0x12345678 << -32 == 0)
ok(0x12345678 >> 4 == 0x01234567)
ok(0x12345678 >> 32 == 0)
ok(0x12345678 >> -32 == 0x1234567800000000)

print("+")

local cs = {0, 1, 2, 3, 10, 0x80000000, 0xaaaaaaaa, 0x55555555, 0xffffffff, 0x7fffffff}
for _, x in ipairs(cs) do
  ok(bit32.band(x) == x)
  ok(bit32.band(x, x, x, x) == x)
  ok(bit32.btest(x, x) == (x ~= 0))
  ok(bit32.band(x, x, x, ~x) == 0)
  ok(bit32.band(x, bit32.bnot(x)) == 0)
  ok(bit32.bor(x, bit32.bnot(x)) == bit32.bnot(0))
  ok(bit32.bor(x, x, 0, ~x) == 0xffffffff)
  ok(bit32.bxor(x, x) == 0)
  ok(bit32.bxor(x, 0) == x)
  ok(bit32.bnot(bit32.bnot(x)) == x)
  ok(bit32.bnot(x) == (1 << 32) - 1 - x)
  ok(bit32.lrotate(x, 32) == x)
  ok(bit32.rrotate(x, 32) == x)
end

-- extract / replace
ok(bit32.extract(0x12345678, 0, 4) == 8)
ok(bit32.extract(0x12345678, 4, 4) == 7)
ok(bit32.extract(0xa0001111, 28, 4) == 0xa)
ok(bit32.extract(0xf2345679, 0, 32) == 0xf2345679)
ok(bit32.replace(0x12345678, 5, 28, 4) == 0x52345678)
ok(bit32.replace(0x12345678, 0x87654321, 0, 32) == 0x87654321)
ok(bit32.replace(-1, 0, 31) == (1 << 31) - 1)

-- float coercion in bit ops
ok(bit32.bor(3.0) == 3)
ok(bit32.bor(-4.0) == 0xfffffffc)

print("checks=" .. checks)
print('OK')
