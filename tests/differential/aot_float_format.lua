-- Float<->text formatting must be byte-identical to the reference interpreter.
--
-- Compiled output routes Lua's __mingw_sprintf/__mingw_fprintf/__mingw_strtod to
-- the UCRT (clua/src/runtime/mingw_stdio_shim.c) instead of carrying MinGW's
-- static gdtoa/pformat, which is worth ~41 KB in every emitted PE. The oracle
-- deliberately stays on MinGW's implementation, so this file is comparing two
-- genuinely different formatters rather than one against itself.
--
-- The interesting cases are the ones where the two disagree unless corrected:
--   * NEGATIVE NaN -- UCRT prints "-nan(ind)", MinGW prints "nan".
--   * SIGNALLING NaN -- UCRT prints "nan(snan)", MinGW prints "nan". This is the
--     one that a fabs()-based fix misses, because fabs clears the sign bit but not
--     the quiet bit. It is reachable with no arithmetic and no FFI: string.unpack
--     writes the raw bit pattern straight into a TValue.
--   * %p -- MinGW writes 16 lowercase hex digits with no 0x; UCRT writes
--     uppercase. Addresses are nondeterministic so the value cannot be diffed;
--     tests/differential/aot_pointer_case.lua asserts the shape instead.

local function show(v) return (tostring(v)) end

-- Ordinary values, integer/float subtype boundaries, and the %.14g default.
local vals = {
  0, 1, -1, 0.0, -0.0, 0.5, -0.5, 1/3, 2/3,
  1e-300, 1e300, 1e15, 1e16, 123456789012345, 1234567890123456,
  math.pi, math.huge, -math.huge,
  math.maxinteger, math.mininteger,
  2^53, 2^53 + 1, 5e-324,            -- smallest subnormal
}
for i, v in ipairs(vals) do
  io.write(("v%02d %s\n"):format(i, show(v)))
end

-- Every float conversion Lua exposes, over values that stress rounding.
-- %F is deliberately absent: Lua 5.4's string.format rejects it as an invalid
-- conversion, so including it would only compare two error messages.
local fmts = { "%.14g", "%.17g", "%g", "%G", "%e", "%E", "%f", "%.3f",
               "%+.3f", "%10.4e", "%-12.2f|", "%a", "%A" }
local probe = { 0.0, -0.0, 1/3, 1e300, 5e-324, math.pi, 255.5, -255.5 }
for _, f in ipairs(fmts) do
  local parts = {}
  for _, v in ipairs(probe) do parts[#parts+1] = string.format(f, v) end
  io.write(f, " -> ", table.concat(parts, " "), "\n")
end

-- NaN, all three flavours, through every path that can format one.
local qnan   = 0/0                                              -- quiet, sign varies
local nqnan  = -(0/0)
local snan   = string.unpack("<d", "\x01\x00\x00\x00\x00\x00\xf0\x7f")
local snan2  = string.unpack("<d", "\xef\xbe\xad\xde\x00\x00\xf0\x7f")
for name, v in pairs({}) do end   -- keep ordering deterministic below
local nans = { { "qnan", qnan }, { "nqnan", nqnan }, { "snan", snan }, { "snan2", snan2 } }
for _, pair in ipairs(nans) do
  local name, v = pair[1], pair[2]
  io.write(name, " tostring=", tostring(v), "\n")
  io.write(name, " fmts=",
    string.format("%.14g|%.14G|%g|%G|%e|%f|%+.3f|%10.4e|%-12.2f|", v, v, v, v, v, v, v, v, v),
    "\n")
  io.write(name, " hex=", string.format("%a|%A", v, v), "\n")
  -- io.write of a float goes through fprintf, a different shim entry point
  io.write(name, " iowrite=") io.write(v) io.write("\n")
  io.write(name, " isnan=", tostring(v ~= v), "\n")
end

-- strtod: the reverse direction, including hex floats and halfway ties.
local strs = { "1", "0.5", "1e300", "1e-300", "5e-324", "0x1p4", "0x1.8p1",
               "1.7976931348623157e308", "2.2250738585072014e-308",
               "0.1", "1e999", "-1e999",
               "9007199254740993", "1.0000000000000002" }
for _, s in ipairs(strs) do
  io.write("tonumber(", s, ")=", tostring(tonumber(s)), "\n")
end

-- Round trip: %.17g must reparse to the identical double.
local rt = { 1/3, math.pi, 1e300, 5e-324, 0.1, 255.5 }
for _, v in ipairs(rt) do
  local s = string.format("%.17g", v)
  io.write("rt ", s, " -> ", tostring(tonumber(s) == v), "\n")
end

print("DONE")
