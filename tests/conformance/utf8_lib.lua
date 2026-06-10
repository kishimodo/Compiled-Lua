-- utf8_lib.lua : the utf8 library -- char, codepoint, len, offset, codes, charpattern.
-- Uses explicit code points so source encoding doesn't matter.
-- Deterministic; JIT and -i must agree byte-for-byte.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end
local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- utf8.char builds a UTF-8 string from code points (1..4 byte sequences)
local s = utf8.char(0x41, 0xE9, 0x20AC, 0x1F600)      -- A  é  €  😀
show(hex(s))
show(#s)                                              -- raw byte length
show(utf8.len(s))                                     -- 4 code points

-- per-byte-width samples
show(hex(utf8.char(0x24)))                            -- 1 byte:  24
show(hex(utf8.char(0xA2)))                            -- 2 bytes: c2 a2
show(hex(utf8.char(0x20AC)))                          -- 3 bytes: e2 82 ac
show(hex(utf8.char(0x10348)))                         -- 4 bytes: f0 90 8d 88

-- codepoint: extract code points by byte range
show(utf8.codepoint(s))                              -- first cp: 0x41 = 65
show(utf8.codepoint(s, 1, #s))                       -- all code points

-- len with a byte range, and len of a pure-ASCII string
show(utf8.len("hello"))
show(utf8.len(s, 1, #s))

-- offset: byte position of the n-th code point (1-based char index)
show(utf8.offset(s, 1))                              -- 1
show(utf8.offset(s, 2))                              -- 2 (after 1-byte A)
show(utf8.offset(s, 3))                              -- 4 (after é which is 2 bytes)
show(utf8.offset(s, 4))                              -- 7
show(utf8.offset(s, -1))                             -- start of last char

-- codes: iterate (bytepos, codepoint) pairs
do
  local out = {}
  for pos, cp in utf8.codes(s) do
    out[#out+1] = pos .. ":" .. cp
  end
  show(table.concat(out, " "))
end

-- charpattern: count characters via gmatch, reconstruct
do
  local count = 0
  for _ in string.gmatch(s, utf8.charpattern) do count = count + 1 end
  show("charpattern count", count)
end

-- round trip: decode then re-encode
do
  local cps = {utf8.codepoint(s, 1, #s)}
  local rebuilt = utf8.char(table.unpack(cps))
  show(rebuilt == s, #cps)
end

-- utf8.len returns nil + position on invalid byte sequence
show(utf8.len("\xff\xfe"))                            -- nil 1 (false position)
