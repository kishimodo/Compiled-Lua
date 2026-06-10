-- tests/lua/test_utf8.lua : utf8 library: char, codepoint, len, offset, charpattern
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_utf8: " .. tostring(m)) end end

-- 1. utf8.char: encode codepoints to UTF-8 bytes
ok(utf8.char(65)        == "A",    "utf8.char(65) == 'A'")
ok(utf8.char(0x41)      == "A",    "utf8.char(0x41) == 'A'")
ok(utf8.char(0xE9)      == "\xC3\xA9", "utf8.char(0xE9) == U+00E9 (é)")  -- 2-byte UTF-8
ok(utf8.char(0x4E2D)    == "\xE4\xB8\xAD", "utf8.char(0x4E2D) == U+4E2D (中)")  -- 3-byte
ok(utf8.char(65, 66, 67) == "ABC", "utf8.char multiple codepoints")
ok(utf8.char(0x1F600)   == "\xF0\x9F\x98\x80", "utf8.char(0x1F600) 4-byte emoji")

-- 2. utf8.codepoint: decode UTF-8 to codepoints
ok(utf8.codepoint("A")         == 65,    "codepoint('A') == 65")
ok(utf8.codepoint("\xC3\xA9")  == 0xE9,  "codepoint(é) == 0xE9")
ok(utf8.codepoint("\xE4\xB8\xAD") == 0x4E2D, "codepoint(中) == 0x4E2D")
ok(utf8.codepoint("\xF0\x9F\x98\x80") == 0x1F600, "codepoint(emoji) == 0x1F600")

-- utf8.codepoint with range
do
  local a, b, c = utf8.codepoint("ABC", 1, 3)
  ok(a == 65 and b == 66 and c == 67, "codepoint range 'ABC' 1,3")
end

-- 3. utf8.len: count characters (not bytes)
ok(utf8.len("ABC")    == 3, "utf8.len 'ABC' == 3")
ok(utf8.len("") == 0,        "utf8.len '' == 0")
-- é is 2 bytes but 1 char
ok(utf8.len("\xC3\xA9") == 1, "utf8.len é == 1 char")
-- 中 is 3 bytes but 1 char
ok(utf8.len("\xE4\xB8\xAD") == 1, "utf8.len 中 == 1 char")
-- mixed: "Héllo" = H(1) + é(2) + l(1) + l(1) + o(1) = 5 chars, 6 bytes
local mixed = "H\xC3\xA9llo"
ok(utf8.len(mixed) == 5,  "utf8.len mixed 5 chars")
ok(#mixed == 6,            "# mixed 6 bytes")

-- utf8.len with start/end positions
ok(utf8.len("ABCDE", 2, 4) == 3, "utf8.len with range 2..4")

-- 4. utf8.offset: byte offset of n-th character
ok(utf8.offset("ABC", 1) == 1,   "offset char 1 == 1")
ok(utf8.offset("ABC", 2) == 2,   "offset char 2 == 2")
ok(utf8.offset("ABC", 3) == 3,   "offset char 3 == 3")
-- With multi-byte chars: "Héllo" — H=1, é=2..3, l=4, l=5, o=6
ok(utf8.offset(mixed, 1) == 1,   "offset mixed char 1 == 1 (H)")
ok(utf8.offset(mixed, 2) == 2,   "offset mixed char 2 == 2 (é starts)")
ok(utf8.offset(mixed, 3) == 4,   "offset mixed char 3 == 4 (first l)")
ok(utf8.offset(mixed, 5) == 6,   "offset mixed char 5 == 6 (o)")
-- Negative index: from end
ok(utf8.offset("ABC", -1) == 3,  "offset -1 (last char) == 3 in 'ABC'")

-- 5. utf8.charpattern
-- The charpattern matches a single UTF-8 encoded character
ok(type(utf8.charpattern) == "string", "charpattern is a string")
do
  local chars = {}
  for c2 in string.gmatch(mixed, utf8.charpattern) do
    chars[#chars+1] = c2
  end
  ok(#chars == 5, "charpattern gmatch finds 5 chars in mixed string")
  ok(chars[1] == "H",           "charpattern char[1] == 'H'")
  ok(chars[2] == "\xC3\xA9",    "charpattern char[2] == é (2 bytes)")
  ok(chars[3] == "l",            "charpattern char[3] == 'l'")
end

-- 6. Round-trip: char -> codepoint
do
  local cps = {65, 0xE9, 0x4E2D, 0x1F600, 0x10FFFD}
  for _, cp in ipairs(cps) do
    local encoded = utf8.char(cp)
    local decoded = utf8.codepoint(encoded)
    ok(decoded == cp, "round-trip codepoint " .. string.format("U+%04X", cp))
  end
end

-- 7. utf8.len with invalid UTF-8 returns nil + position
do
  local bad = "\xFF\xFE"  -- invalid UTF-8
  local n, pos = utf8.len(bad)
  ok(n == nil, "utf8.len on invalid UTF-8 returns nil")
  ok(type(pos) == "number", "utf8.len on invalid UTF-8 returns error position")
end

if fails == 0 then print("[+] PASS test_utf8") os.exit(0) else os.exit(1) end
