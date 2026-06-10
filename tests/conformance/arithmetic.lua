-- arithmetic.lua : full arithmetic incl. //, %, ^ sign rules across int/float.
-- Deterministic; JIT and -i must agree byte-for-byte.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- floor division // : result type follows operand types; floors toward -inf
show(7 // 2, -7 // 2, 7 // -2, -7 // -2)            -- 3 -4 -4 3
show(7.0 // 2, 7 // 2.0, -7.5 // 2, 7.5 // -2)      -- floats, floored
show(math.type(7 // 2), math.type(7.0 // 2))
show(5.0 // 0, -5.0 // 0, 0.0 // 0)                 -- inf -inf nan (float floordiv by 0)

-- modulo % : result has sign of the DIVISOR (Lua/Python semantics)
show(7 % 3, -7 % 3, 7 % -3, -7 % -3)               -- 1 2 -2 -1
show(5.5 % 2, -5.5 % 2, 5.5 % -2, -5.5 % -2)       -- float mod sign rules
show(math.type(7 % 3), math.type(7.0 % 3))
show(5.0 % 0)                                       -- nan (float mod 0)

-- a == (a // b) * b + (a % b) identity
do
  local ok = true
  for _, a in ipairs({17, -17, 100, -100}) do
    for _, b in ipairs({5, -5, 3, -3}) do
      if a // b * b + a % b ~= a then ok = false end
    end
  end
  show("floordiv/mod identity", ok)
end

-- exponentiation ^ : ALWAYS produces a float, even for integer operands
show(2^10, 2^0, 2^-1, math.type(2^2))
show((-2)^2, (-2)^3, (-8)^(1/3))                   -- last is nan (negative base, frac exp)
show(2^0.5, 4^0.5, 9^0.5)
show(0^0, 0^1, 1^0)                                -- 1.0 0.0 1.0

-- unary minus / negation across subtypes
show(-5, -5.0, -math.maxinteger, -(2^63))
show(math.type(-5), math.type(-5.0))

-- mixed-type arithmetic promotes to float
show(1 + 2, 1 + 2.0, 1.5 + 2, math.type(1 + 2), math.type(1 + 2.0))
show(10 / 3, 10 / 2, math.type(10 / 2))            -- / always float

-- chained precedence (^ right-assoc, binds tighter than unary minus)
show(2^2^3, -2^2, 2 + 3 * 4, (2 + 3) * 4)          -- 256.0 -4.0 14 20
show(2 * 3 % 4, 10 - 2 - 3, 2^-2)                  -- 2 5 0.25
