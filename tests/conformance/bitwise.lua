-- bitwise.lua : & | ~ << >> on edge values. 64-bit integer semantics.
-- Deterministic; JIT and -i must agree byte-for-byte.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

local MAX = math.maxinteger
local MIN = math.mininteger

-- basic AND / OR / XOR
show(0xF0 & 0x0F, 0xF0 | 0x0F, 0xFF ~ 0x0F)        -- 0 255 240
show(0xAAAA & 0x5555, 0xAAAA | 0x5555, 0xAAAA ~ 0xAAAA)

-- unary bitwise NOT (~x == -x-1)
show(~0, ~1, ~-1, ~MAX, ~MIN)                      -- -1 -2 0 MIN MAX
show(~0 == -1, ~MAX == MIN, ~MIN == MAX)

-- shifts: left/right are logical (zero-fill); negative count shifts other way
show(1 << 0, 1 << 1, 1 << 63, 1 << 64)             -- 1 2 MIN 0
show(0xFF << 4, 0xFF >> 4, 1 << -1, 256 >> -1)     -- 4080 15 0 512
show(MIN >> 63, MIN >> 1, -1 >> 1)                 -- logical: 1, large+, MAX
show(-1 >> 0, -1 >> 64, -1 << 64)                  -- -1 0 0 (shift >=64 -> 0)

-- shift by 64+ yields 0 (both directions)
show(1 << 100, 1 >> 100, MAX << 65, MAX >> 65)

-- whole-word patterns
show(MAX & MIN, MAX | MIN, MAX ~ MIN)              -- 0 -1 -1
show(0 | MIN, MIN & MIN)

-- float operands with integer value are accepted (3.0 -> 3); non-integral errors
show(3.0 & 1, 12.0 | 3, 5.0 ~ 1.0)
show(math.type(0xFF & 0x0F))                       -- integer (bitops always int)

-- de Morgan and identities over a sample
do
  local ok = true
  for _, x in ipairs({0, 1, -1, 255, MAX, MIN, 0x123456789ABCDEF}) do
    for _, y in ipairs({0, -1, 0xFF, MIN, 42}) do
      if (~(x & y)) ~= (~x | ~y) then ok = false end
      if (x ~ y) ~ y ~= x then ok = false end          -- xor is its own inverse
      if (x | y) & ~(x & y) ~= (x ~ y) then ok = false end
    end
  end
  show("bit identities", ok)
end

-- packing bytes via shifts
do
  local b0, b1, b2, b3 = 0xDE, 0xAD, 0xBE, 0xEF
  local word = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  show(word, (word >> 24) & 0xFF, (word >> 16) & 0xFF, word & 0xFF)
end
