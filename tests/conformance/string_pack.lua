-- string_pack.lua : string.pack / unpack / packsize across format codes.
-- Uses explicit endianness so output is host-independent. Bytes shown as hex.
-- Deterministic; JIT and -i must agree byte-for-byte.

local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- integer codes, little-endian, explicit widths
show(hex(string.pack("<i1", 0x12)))
show(hex(string.pack("<i2", 0x1234)))
show(hex(string.pack("<i4", 0x12345678)))
show(hex(string.pack("<i8", 0x123456789ABCDEF0)))
show(hex(string.pack(">i4", 0x12345678)))               -- big-endian
show(hex(string.pack("<I2 <I4", 0xFFFF, 0xFFFFFFFF)))   -- unsigned

-- round-trip integers incl. signedness
show(string.unpack("<i4", string.pack("<i4", -1)))
show(string.unpack("<i2", string.pack("<i2", -32768)))
show(string.unpack(">i8", string.pack(">i8", math.mininteger)))
show(string.unpack("<I1", string.pack("<I1", 255)))

-- the second return of unpack is the next position
show(string.unpack("<i2", "\x01\x02\xff", 1))           -- value, nextpos=3

-- floats: f (single) and d (double) and n (lua number)
do
  local s = string.pack("<d", 3.5)
  show(hex(s), string.unpack("<d", s))
end
show(string.unpack("<f", string.pack("<f", 1.5)))       -- 1.5 exact in float
show(string.unpack("<n", string.pack("<n", 2.25)))

-- booleans-as-bytes via i1, and the 'x' padding byte
show(hex(string.pack("<i1 x i1", 1, 2)))                -- 01 00 02

-- strings: z (zero-terminated), s (size-prefixed), fixed-size with cN
show(hex(string.pack("z", "hi")))                       -- 68 69 00
show(string.unpack("z", string.pack("z", "world")))
show(hex(string.pack("<s4", "abc")))                    -- len(4 bytes LE) + abc
show(string.unpack("<s4", string.pack("<s4", "hello")))
show(hex(string.pack("c5", "ab")))                      -- padded with \0 to 5

-- alignment with '!' and the native-but-pinned sizes via explicit widths
-- (use I1 unsigned for 0xAB, which is out of range for signed i1)
show(hex(string.pack("<!4 I1 i4", 0xAB, 0x11223344)))   -- align i4 to 4

-- packsize for fixed-size formats
show(string.packsize("<i4"), string.packsize("<i8 i2"), string.packsize("<dd"))
show(string.packsize("c10"), string.packsize("<!8 i1 i8"))

-- multiple values in one call, mixed codes
do
  local packed = string.pack("<i2 i4 d", 7, 100000, 1.25)
  local a, b, c, pos = string.unpack("<i2 i4 d", packed)
  show(a, b, c, pos)
end
