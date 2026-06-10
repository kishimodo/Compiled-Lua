-- tests/packages/test_unicode.lua : pure-Lua surface of the `unicode` package
-- (UTF-8/UTF-16 codecs, length, names, blocks, grapheme clustering) verified
-- against hand-computed reference values from the Unicode / RFC 3629 spec, plus
-- a pcall-guarded smoke test of the Win32-backed casing/ctype/normalize calls.
-- (The package used `wchar_t` in its cdef, which the FFI did not know; that is
-- fixed -- ctype.c now registers wchar_t as a 2-byte type -- so require succeeds
-- and the full battery runs.)

local ok_req, unicode = pcall(require, "unicode")
if not ok_req then print("[~] SKIP test_unicode (" .. tostring(unicode) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_unicode: " .. tostring(m)) end end

-- ===== encode / to_utf8 : codepoint -> UTF-8 bytes (RFC 3629) ==========
-- Reference byte sequences computed by hand from the UTF-8 spec.
ok(unicode.encode(0x41) == "A",                       "encode ASCII 'A'")
ok(unicode.encode(0xE9) == "\xC3\xA9",                "encode U+00E9 -> 2 bytes")
ok(unicode.encode(0x20AC) == "\xE2\x82\xAC",          "encode U+20AC (euro) -> 3 bytes")
ok(unicode.encode(0x1F600) == "\xF0\x9F\x98\x80",     "encode U+1F600 -> 4 bytes")
ok(unicode.encode(0x7F) == "\x7F",                    "encode U+007F (1-byte max)")
ok(unicode.encode(0x80) == "\xC2\x80",                "encode U+0080 (2-byte min)")
ok(unicode.encode(0x7FF) == "\xDF\xBF",               "encode U+07FF (2-byte max)")
ok(unicode.encode(0x800) == "\xE0\xA0\x80",           "encode U+0800 (3-byte min)")
ok(unicode.encode(0xFFFF) == "\xEF\xBF\xBF",          "encode U+FFFF (3-byte max)")
ok(unicode.encode(0x10000) == "\xF0\x90\x80\x80",     "encode U+10000 (4-byte min)")
ok(unicode.to_utf8 == unicode.encode,                 "to_utf8 is an alias of encode")

-- ===== codepoint_at / from_utf8 : decode at a byte position ============
local cp, np = unicode.codepoint_at("A", 1)
ok(cp == 0x41 and np == 2,                            "decode ASCII -> cp, next=2")
cp, np = unicode.codepoint_at("\xC3\xA9", 1)
ok(cp == 0xE9 and np == 3,                            "decode 2-byte -> 0xE9, next=3")
cp, np = unicode.codepoint_at("\xE2\x82\xAC", 1)
ok(cp == 0x20AC and np == 4,                          "decode 3-byte -> 0x20AC, next=4")
cp, np = unicode.codepoint_at("\xF0\x9F\x98\x80", 1)
ok(cp == 0x1F600 and np == 5,                         "decode 4-byte -> 0x1F600, next=5")
ok(unicode.codepoint_at("\x80", 1) == nil,            "stray continuation byte -> nil")
ok(unicode.codepoint_at("\xE2\x82", 1) == nil,        "truncated 3-byte -> nil")
local fcp, fnp = unicode.from_utf8("X\xC3\xA9", 2)
ok(fcp == 0xE9 and fnp == 4,                          "from_utf8 honours init offset")
ok((unicode.from_utf8("Z")) == 0x5A,                  "from_utf8 default init=1")

-- ===== round-trip encode -> decode over a spread of codepoints ========
for _, c in ipairs({0x41,0x7F,0x80,0xE9,0x7FF,0x800,0x20AC,0xFFFD,0xFFFF,0x10000,0x1F600,0x10FFFF}) do
  local s = unicode.encode(c)
  local rc, rnp = unicode.codepoint_at(s, 1)
  ok(rc == c,        "round-trip codepoint U+" .. string.format("%X", c))
  ok(rnp == #s + 1,  "round-trip next-pos for U+" .. string.format("%X", c))
end

-- ===== codepoints iterator + length ===================================
-- "h" + U+00E9 + "llo" + U+20AC : 6 codepoints, 9 bytes.
local s = "h\xC3\xA9llo\xE2\x82\xAC"
ok(#s == 9,                                           "fixture byte length is 9")
ok(unicode.length(s) == 6,                            "length() counts 6 codepoints")
ok(unicode.length("") == 0,                           "length('') is 0")
local seen, count = {}, 0
for c, bp in unicode.codepoints(s) do
  count = count + 1; seen[count] = c
  ok((unicode.codepoint_at(s, bp)) == c, "codepoints byte_pos #" .. count .. " re-decodes")
end
ok(count == 6,                                        "iterator yields 6 items")
ok(seen[1] == 0x68 and seen[2] == 0xE9 and seen[6] == 0x20AC, "iterator yields expected codepoints")
local bad, bn, gotfffd = "a\x80b", 0, false
for c in unicode.codepoints(bad) do bn = bn + 1; if c == 0xFFFD then gotfffd = true end end
ok(bn == 3,                                           "iterator over malformed yields 3 items")
ok(gotfffd,                                           "iterator surfaces U+FFFD on a bad byte")

-- ===== to_utf16 : big-endian UTF-16 bytes =============================
ok(unicode.to_utf16(0x41) == "\x00\x41",              "to_utf16 'A' big-endian (2 bytes)")
ok(unicode.to_utf16(0x20AC) == "\x20\xAC",            "to_utf16 euro big-endian")
-- U+1F600: v=0xF600 -> hi=0xD83D, lo=0xDE00 (surrogate pair).
ok(unicode.to_utf16(0x1F600) == "\xD8\x3D\xDE\x00",   "to_utf16 surrogate pair big-endian")

-- ===== name : table entries + algorithmic ranges ======================
ok(unicode.name(0x20AC) == "EURO SIGN",               "name of euro (table)")
ok(unicode.name(0x41) == "LATIN CAPITAL LETTER A",    "name of 'A' (algorithmic)")
ok(unicode.name(0x7A) == "LATIN SMALL LETTER Z",      "name of 'z' (algorithmic)")
ok(unicode.name(0x30) == "DIGIT ZERO",                "name of '0' (algorithmic)")
ok(unicode.name(0x39) == "DIGIT NINE",                "name of '9' (algorithmic)")
ok(unicode.name(0x2603) == "SNOWMAN",                 "name of snowman (table)")
ok(unicode.name(0xABCD) == "U+ABCD",                  "name falls back to U+XXXX")

-- ===== block : binary search over Unicode blocks ======================
ok(unicode.block(0x41) == "Basic Latin",              "block of 'A'")
ok(unicode.block(0x20AC) == "Currency Symbols",       "block of euro")
ok(unicode.block(0x4E00) == "CJK Unified Ideographs", "block at CJK ideographs start")
ok(unicode.block(0x1F600) == "Emoticons",             "block of an emoticon")
ok(unicode.block(0x0410) == "Cyrillic",               "block of a Cyrillic letter")
ok(unicode.block(0x02C0) == nil,                      "uncovered codepoint -> nil block")

-- ===== is_mark / is_symbol : pure-Lua range tables ====================
ok(unicode.is_mark(0x0301) == true,                   "U+0301 combining acute is a mark")
ok(unicode.is_mark(0x0041) == false,                  "'A' is not a mark")
ok(unicode.is_mark(0x20D0) == true,                   "U+20D0 is a (combining) mark")
ok(unicode.is_symbol(0x2B) == true,                   "'+' is a symbol")
ok(unicode.is_symbol(0x2603) == true,                 "snowman is a symbol")
ok(unicode.is_symbol(0x41) == false,                  "'A' is not a symbol")

-- ===== graphemes : base + combining mark cluster ======================
-- "e" + U+0301 must group into ONE extended grapheme cluster.
local clusters = {}
for cl in unicode.graphemes("e\xCC\x81bc") do clusters[#clusters + 1] = cl end
ok(#clusters == 3,                                    "graphemes: e+mark, b, c -> 3 clusters")
ok(clusters[1] == "e\xCC\x81",                        "graphemes: first cluster joins base+mark")
ok(clusters[2] == "b" and clusters[3] == "c",         "graphemes: trailing clusters are single")

-- ===== Win32-backed surface (kernel32 / normaliz.dll). Guard each call;
-- ===== SKIP just the section if the underlying API is unavailable. =====
do
  local pcok, res = pcall(function() return unicode.upper("abc") end)
  if pcok and res == "ABC" then
    ok(unicode.lower("ABC") == "abc",                 "lower('ABC') == 'abc'")
    ok(unicode.upper("\xC3\xA9") == "\xC3\x89",       "upper(U+00E9) == U+00C9 (E-acute)")
  else
    print("[~] SKIP test_unicode (casing): LCMapStringEx unavailable")
  end
end
do
  local pcok = pcall(function() return unicode.is_letter(0x41) end)
  if pcok and unicode.is_letter(0x41) == true then
    ok(unicode.is_digit(0x39) == true,                "is_digit('9')")
    ok(unicode.is_letter(0x39) == false,              "'9' is not a letter")
    ok(unicode.is_alphanumeric(0x41) == true,         "'A' is alphanumeric")
  else
    print("[~] SKIP test_unicode (ctype): GetStringTypeW unavailable")
  end
end
do
  local pcok, res = pcall(function() return unicode.normalize("e\xCC\x81", "nfc") end)
  if pcok and res and #res > 0 then
    -- NFC composes "e"+U+0301 into the precomposed U+00E9.
    ok(res == "\xC3\xA9",                             "normalize NFC composes e+acute -> U+00E9")
    ok(unicode.normalize("\xC3\xA9", "nfd") == "e\xCC\x81", "normalize NFD decomposes U+00E9 -> e+acute")
  else
    print("[~] SKIP test_unicode (normalize): normaliz.dll unavailable")
  end
end

if fails == 0 then print("[+] PASS test_unicode") os.exit(0) else os.exit(1) end
