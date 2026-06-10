-- strings_format.lua : string.format across conversions + edge cases.
-- Deterministic; JIT and -i must agree byte-for-byte.

local F = string.format

-- integer conversions
print(F("%d %i %5d %-5d| %05d", 42, -42, 7, 7, 7))
print(F("%x %X %o %#x", 255, 255, 8, 255))
print(F("%u", 42))
print(F("[%+d][%+d][% d]", 5, -5, 5))

-- the integer extremes via %d
print(F("%d %d", math.maxinteger, math.mininteger))

-- float conversions
print(F("%f %.2f %.0f %10.3f", 3.14159, 3.14159, 3.7, 3.14159))
print(F("%e %E %.2e", 12345.678, 12345.678, 12345.678))
print(F("%g %g %g", 0.0001, 100000.0, 1000000.0))
print(F("%g %g", 1/3, 1e100))
print(F("%a", 1.0))                                  -- hex float; 0x1p+0

-- %g of integers-as-floats and specials
print(F("%g %g %g", 1/0, -1/0, 0/0))                 -- inf -inf and a nan spelling

-- strings: %s with width/precision, %q quoting
print(F("[%s][%10s][%-10s][%.3s]", "hi", "hi", "hi", "hello"))
print(F("%q", "tab\tnewline\nquote\"backslash\\"))
print(F("%q", "embedded\0zero"))

-- %c character, %% literal percent
print(F("%c%c%c %%", 72, 105, 33))

-- argument reuse via multiple specifiers and a long mixed string
print(F("%s=%d (%.1f%%)", "rate", 95, 95.5))

-- tostring fallback for %s on non-strings
print(F("%s %s %s", true, nil, 3.0))

-- format integer with hex of negative (two's complement width)
print(F("%x", -1))
print(F("%016x", 0xABCDEF))

-- %s with a table having __tostring
do
  local t = setmetatable({}, {__tostring = function() return "OBJ" end})
  print(F("val=%s", t))
end
