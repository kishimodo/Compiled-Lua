-- numbers_subtypes.lua : integer/float subtypes, math.type, tostring rules,
-- integer/float overflow + wraparound. Deterministic; JIT and -i must agree.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring((select(i, ...)))
  end
  print(table.concat(parts, "\t"))
end

-- math.type classification
show(math.type(1), math.type(1.0), math.type("1"), math.type(2^53))
show(math.type(math.maxinteger), math.type(math.mininteger))

-- tostring of integers vs floats (the canonical %.14g / integer rendering)
show(tostring(1), tostring(1.0), tostring(-0.0), tostring(0.0))
show(tostring(100), tostring(1e100), tostring(0.1), tostring(1/3))
show(tostring(3.0), tostring(3.5), tostring(2^53), tostring(10.0))

-- integer / float boundary constants
show(math.maxinteger, math.mininteger)
show(math.maxinteger + 1 == math.mininteger)        -- wraparound: true
show(math.mininteger - 1 == math.maxinteger)        -- true
show(math.maxinteger * 2)                            -- -2 (two's complement wrap)
show(math.mininteger * -1 == math.mininteger)       -- true (overflow stays)

-- integer<->float equality and ordering across the representable boundary
show(1 == 1.0, 1.0 == 1, 2^53 == (2^53 + 1))         -- true true true (float precision)
show(math.maxinteger < math.huge, math.mininteger > -math.huge)

-- float specials
show(1/0, -1/0, math.huge, -math.huge)
show(0/0 ~= 0/0)                                     -- NaN: true
show(math.huge == math.huge, -math.huge < math.huge)

-- explicit conversions
show(math.tointeger(3.0), math.tointeger(3.5), math.tointeger(2^53))
show(math.tointeger(math.huge), math.tointeger(2.0^63))
show(0x7fffffffffffffff, 0xffffffffffffffff)         -- hex int literals incl. wrap
show(math.floor(3.7), math.ceil(3.2), math.floor(-3.2), math.ceil(-3.7))
show(math.type(math.floor(3.7)), math.type(math.floor(2.0^63)))

-- integer-valued float forced via division/conversion
show(10 // 1, 10.0 // 1, 7 // 2, 7.0 // 2.0)
show(math.type(10 // 1), math.type(10.0 // 1))
