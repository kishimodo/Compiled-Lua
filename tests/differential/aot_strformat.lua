-- aot_strformat.lua — number/string formatting fidelity stress.
--
-- Guards the printf/strtod implementation the compiled exe links (e.g. the
-- MinGW-ANSI-stdio vs ucrt choice): string.format, tostring of floats,
-- integer/float printing, %a hex floats, huge/denormal/negative-zero corners,
-- and tonumber parsing round-trips. Runs under the aotdiff layer (compiled
-- PE vs luavm -i, byte-identical stdout required) and the plain JIT-vs-i
-- differential.

local function p(...) print(...) end

-- %d / %i / %x / %X / %o / %c / %u-like widths
p(("%d|%5d|%-5d|%05d"):format(42, 42, 42, 42))
p(("%d %d %d"):format(math.maxinteger, math.mininteger, 0))
p(("%x|%X|%#x|%08x"):format(48879, 48879, 48879, 48879))
p(("%o|%c|%%"):format(511, 65))

-- %s / %q / precision
p(("%s|%10s|%-10s|%.3s"):format("hi", "hi", "hi", "truncate"))
p(("%q"):format('quote " backslash \\ newline \n tab \t del \127'))

-- %f / %e / %g default and explicit precision
p(("%f|%e|%g"):format(1.5, 1.5, 1.5))
p(("%.0f|%.1f|%.10f"):format(2.5, 2.45, 1/3))
p(("%e|%E|%.0e"):format(12345.6789, 12345.6789, 12345.6789))
p(("%g|%G|%.17g"):format(0.1, 0.1, 0.1))
p(("%g|%g|%g"):format(1e-5, 1e-4, 123456789))
p(("%.14g"):format(2^53))
p(("%.14g"):format(-2^53))

-- float tostring path (lua_Number -> %.14g)
p(1/3, 2/3, 0.1, 0.2, 0.3)
p(1e15, 1e16, 1e100, 1e-100, 1e308)
p(2^63, -2^63, 2^31, 2^52 + 0.5)

-- corners: infinities, negative zero, denormals
p(math.huge, -math.huge)
p(0.0, -0.0, 1/math.huge, -1/math.huge)
p(5e-324, 2.2250738585072014e-308)         -- min denormal, min normal
p(("%g|%f|%e"):format(math.huge, math.huge, math.huge))
p(("%g|%f|%e"):format(-math.huge, -math.huge, -math.huge))

-- NaN prints via %.14g; the rendered text must match the oracle exactly
local nan = 0/0
p(nan)
p(("%g"):format(nan))

-- %a hex-float formatting (C99; precision-sensitive across CRTs)
p(("%a"):format(1.0))
p(("%a"):format(0.5))
p(("%a"):format(2^-1074))
p(("%a"):format(1.5))
p(("%a"):format(1/3))

-- tonumber parsing: decimal, hex int, hex float, exponents, denormal
p(tonumber("0x10"), tonumber("0xA.8p1"), tonumber("0x.1p4"))
p(tonumber("1e308"), tonumber("1e309"), tonumber("5e-324"))
p(tonumber("  0x7fffffffffffffff  "), tonumber("9223372036854775808"))
p(tonumber("0x1p-1074"), tonumber("3.1415926535897932384626"))
p(tonumber("inf"), tonumber("nan"))        -- not numbers in Lua: both nil

-- string round-trips through format
local v = 0.30000000000000004
p(tonumber(("%.17g"):format(v)) == v)
p(tostring(2^1023 * 1.9999999999999998))
