-- %p formatting: the one float/pointer property the differential suite cannot
-- check by diffing stdout, because addresses are nondeterministic.
--
-- MinGW's __mingw_pformat writes exactly 16 LOWERCASE hex digits with no "0x"
-- prefix. The UCRT's %p writes UPPERCASE. Compiled output routes Lua's stdio
-- through the UCRT (clua/src/runtime/mingw_stdio_shim.c) to drop ~41 KB of static
-- gdtoa/pformat, so the shim has to reproduce MinGW's spelling itself -- and a
-- stdout diff against the oracle would pass either way, since the digits differ
-- run to run regardless.
--
-- So assert the SHAPE, which is deterministic, and print only the verdicts.
-- Lua reaches this through lua_pointer2str, which always passes the literal "%p"
-- (string.format("%-20p", t) discards the width upstream), so that one shape is
-- the whole reachable surface.

local function check(name, cond)
  print((cond and "ok   " or "FAIL ") .. name)
end

local samples = { {}, {}, print, string.format, coroutine.create(function() end) }

local all_lower, all_len, all_shape = true, true, true
for _, v in ipairs(samples) do
  local s = tostring(v)
  local addr = s:match(": (%x+)$")
  if not addr then
    all_shape = false
  else
    -- No uppercase hex digit anywhere in the address.
    if addr:match("[A-F]") then all_lower = false end
    -- Exactly 16 digits, and no "0x" prefix.
    if #addr ~= 16 then all_len = false end
    if s:match(": 0[xX]") then all_shape = false end
  end
end

check("tostring gives 'type: <hex>'", all_shape)
check("address is lowercase hex", all_lower)
check("address is exactly 16 digits", all_len)

-- string.format("%p") must agree with tostring's address for the same object.
local t = {}
local from_fmt = string.format("%p", t)
local from_tos = tostring(t):match(": (%x+)$")
check("string.format('%p') matches tostring", from_fmt == from_tos)
check("string.format('%p') is 16 chars", #from_fmt == 16)
check("string.format('%p') has no 0x", not from_fmt:match("^0[xX]"))
check("string.format('%p') is lowercase", not from_fmt:match("[A-F]"))

-- A WIDTH changes the rendering, and this is the part that is easy to get wrong.
-- MinGW drops the zero fill entirely once a width is present: "%p" gives 16
-- zero-padded digits but "%20p" gives the MINIMAL hex, space-padded. The UCRT
-- keeps 16 zero-padded digits and uppercases them, so a shim that special-cases
-- only the literal "%p" diverges here -- measured, before this was handled:
--   oracle   "%-20p" -> [6ed330              ]
--   compiled "%-20p" -> [00000000014FFF50    ]
-- Asserted against the plain form rather than a literal, since addresses vary.
local strip = (string.format("%p", t):gsub("^0+", ""))
check("width drops the zero fill", string.format("%2p", t) == strip)
check("width right-pads with spaces",
      string.format("%20p", t) == string.rep(" ", 20 - #strip) .. strip)
check("'-' left-pads with spaces",
      string.format("%-20p", t) == strip .. string.rep(" ", 20 - #strip))
check("width forms stay lowercase",
      not (string.format("%20p", t) .. string.format("%-20p", t)):match("[A-F]"))

-- Lua's own checkformat rejects every other 'p' spec before it reaches the
-- formatter, which is what bounds the shapes the shim has to reproduce.
for _, bad in ipairs({ "%08p", "%.4p", "%#p", "%+p", "% p", "%020p" }) do
  check("Lua rejects " .. bad, not (pcall(string.format, bad, t)))
end

-- Distinct objects must give distinct addresses (i.e. we are not printing a
-- constant), and the same object the same address twice.
check("distinct objects differ", string.format("%p", {}) ~= string.format("%p", {}))
check("same object is stable", string.format("%p", t) == string.format("%p", t))

print("DONE")
