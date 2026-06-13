-- Number/string coercion corners: string<->number arithmetic coercion, tonumber
-- with bases and whitespace, the integer/float boundary, nan/inf, -0.0.

local function show(...)
  local p = {}
  for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
  print(table.concat(p, "\t"))
end

-- string operands coerce in arithmetic (and the RESULT is a number)
show("10" + 5, "3.5" * 2, "0x10" + 0, "  7  " + 0)     -- 15 7.0 16 7
show(math.type("10" + 5), math.type("10" + 0.0))       -- integer float
show(10 .. 20, 1.5 .. "x", "" .. 42)                    -- concat coerces numbers

-- tonumber: bases, whitespace, failures
show(tonumber("  42  "), tonumber("0x1A"), tonumber("1e3"))      -- 42 26 1000.0
show(tonumber("ff", 16), tonumber("777", 8), tonumber("z", 36))  -- 255 511 35
show(tonumber("10", 2), tonumber("zz", 36))                      -- 2 1295
show(tonumber("nan"), tonumber("0x"), tonumber("12abc"), tonumber(""))  -- nil x4
show(tonumber("  -0b "), tonumber("3.", 10) == nil)              -- nil; base form rejects '.'

-- integer/float equality and ordering across subtypes
show(1 == 1.0, 0 == -0.0, 2^53 == 2^53 + 1)            -- true true (float prec) ...
show(math.maxinteger < math.huge, math.mininteger > -math.huge)  -- true true
show(math.maxinteger + 0.0 == math.maxinteger)         -- false (float can't represent it exactly)

-- nan: not equal to itself; not <, not <=, not >
do
  local nan = 0/0
  show(nan == nan, nan ~= nan, nan < nan, nan <= nan, nan > 1, 1 < nan)
end

-- inf arithmetic
show(1/0, -1/0, math.huge - math.huge, math.huge + 1 == math.huge)  -- inf -inf nan true

-- -0.0 displays and behaves
show(-0.0, 0.0 == -0.0, 1/0.0, 1/-0.0)                 -- -0.0 true inf -inf

-- integer overflow wraps (two's complement, modular)
show(math.maxinteger + 1 == math.mininteger)           -- true
show(math.mininteger - 1 == math.maxinteger)           -- true
show(math.maxinteger * 2)                               -- -2 (wraps)

-- math.tointeger / floor/ceil type
show(math.tointeger(3.0), math.tointeger(3.5), math.type(math.floor(3.9)))  -- 3 nil integer

print("[+] PASS number_coercion")
