-- tests/lua/test_strings.lua : string.pack/unpack, format, find/match/gmatch/gsub, byte/char
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_strings: " .. tostring(m)) end end

-- 1. string.byte and string.char
ok(string.byte("A")        == 65,    "byte('A') == 65")
ok(string.byte("ABC", 2)   == 66,    "byte('ABC',2) == 66")
ok(string.byte("ABC", -1)  == 67,    "byte('ABC',-1) == 67 (last char)")
ok(string.char(72, 101, 108, 108, 111) == "Hello", "char(72,101,108,108,111) == 'Hello'")
local b1, b2, b3 = string.byte("xyz", 1, 3)
ok(b1 == 120 and b2 == 121 and b3 == 122, "byte range 'xyz' 1,3")

-- 2. string.format
ok(string.format("%d", 42)         == "42",        "format %d")
ok(string.format("%05d", 42)       == "00042",      "format %05d zero-pad")
ok(string.format("%x", 255)        == "ff",         "format %x hex lower")
ok(string.format("%X", 255)        == "FF",         "format %X hex upper")
ok(string.format("%.3f", math.pi)  == "3.142",      "format %.3f pi")
ok(string.format("%s+%s", "a","b") == "a+b",        "format %s concat")
ok(string.format("%q", 'say "hi"') == '"say \\"hi\\""', "format %q quoting")
ok(string.format("%10s", "hi")     == "        hi", "format right-justify %10s")
ok(string.format("%-10s|", "hi")   == "hi        |","format left-justify %-10s")
ok(string.format("%e", 314.0)      == "3.140000e+02","format %e scientific")

-- 3. string.find
local s = "hello world"
local i, j = string.find(s, "world")
ok(i == 7 and j == 11, "find 'world' in 'hello world': 7,11")
local i2, j2 = string.find(s, "xyz")
ok(i2 == nil and j2 == nil, "find missing returns nil,nil")
local i3, j3 = string.find(s, "l+", 1, false)
ok(i3 == 3, "find pattern 'l+' starts at 3")
-- plain search
local i4, j4 = string.find("a.b.c", ".", 1, true)
ok(i4 == 2 and j4 == 2, "find plain dot at position 2")

-- 4. string.match
ok(string.match("2026-06-07", "(%d+)-(%d+)-(%d+)") == "2026", "match returns first capture")
local y, m2, d = string.match("2026-06-07", "(%d+)-(%d+)-(%d+)")
ok(y == "2026" and m2 == "06" and d == "07", "match multiple captures")
ok(string.match("hello", "^h(.-)o$") == "ell", "match anchored with lazy")
ok(string.match("  trim  ", "^%s*(.-)%s*$") == "trim", "match trim whitespace")
ok(string.match("no digits", "%d+") == nil, "match returns nil on no match")

-- 5. string.gmatch
do
  local words = {}
  for w in string.gmatch("one two three", "%a+") do
    words[#words+1] = w
  end
  ok(#words == 3,           "gmatch word count == 3")
  ok(words[1] == "one",     "gmatch word[1] == 'one'")
  ok(words[3] == "three",   "gmatch word[3] == 'three'")
end

do
  local pairs_found = {}
  for k, v in string.gmatch("a=1, b=2, c=3", "(%a+)=(%d+)") do
    pairs_found[k] = tonumber(v)
  end
  ok(pairs_found["a"] == 1, "gmatch key-value a=1")
  ok(pairs_found["b"] == 2, "gmatch key-value b=2")
  ok(pairs_found["c"] == 3, "gmatch key-value c=3")
end

-- 6. string.gsub
ok(string.gsub("hello world", "o", "0")         == "hell0 w0rld", "gsub basic replace")
local result, count = string.gsub("aaa", "a", "b")
ok(result == "bbb" and count == 3, "gsub count replacements")
ok(string.gsub("hello", "l", "L", 1) == "heLlo", "gsub max replacements limit")
ok(string.gsub("2026-06-07", "(%d+)-(%d+)-(%d+)", "%3/%2/%1") == "07/06/2026", "gsub captures rearrange")
do
  local upper = string.gsub("hello", "%a", string.upper)
  ok(upper == "HELLO", "gsub with function (string.upper)")
end
do
  local tbl = {name="world"}
  local res = string.gsub("hello $name", "%$(%a+)", tbl)
  ok(res == "hello world", "gsub with table replacement")
end

-- 7. string.pack / string.unpack round-trips
do
  -- ">i4" big-endian signed 32-bit
  local packed = string.pack(">i4", 123456)
  ok(#packed == 4, "pack >i4 length is 4")
  local val = string.unpack(">i4", packed)
  ok(val == 123456, "pack/unpack >i4 round-trip")

  -- "<I2" little-endian unsigned 16-bit
  local p2 = string.pack("<I2", 65535)
  ok(#p2 == 2, "pack <I2 length is 2")
  local v2 = string.unpack("<I2", p2)
  ok(v2 == 65535, "pack/unpack <I2 round-trip")

  -- "d" double
  local p3 = string.pack("d", math.pi)
  ok(#p3 == 8, "pack 'd' double length is 8")
  local v3 = string.unpack("d", p3)
  ok(math.abs(v3 - math.pi) < 1e-15, "pack/unpack 'd' double round-trip")

  -- "s1" length-prefixed string
  local p4 = string.pack("s1", "hi")
  local v4, pos4 = string.unpack("s1", p4)
  ok(v4 == "hi", "pack/unpack 's1' string round-trip")
  ok(pos4 == #p4 + 1, "pack/unpack 's1' position after unpack")

  -- "bBhH" signed/unsigned byte and short
  local p5 = string.pack("bBhH", -1, 200, -300, 60000)
  local a, b, c, d = string.unpack("bBhH", p5)
  ok(a == -1,    "pack/unpack 'b' signed byte -1")
  ok(b == 200,   "pack/unpack 'B' unsigned byte 200")
  ok(c == -300,  "pack/unpack 'h' signed short -300")
  ok(d == 60000, "pack/unpack 'H' unsigned short 60000")

  -- "c5" fixed-length string
  local p6 = string.pack("c5", "abcde")
  ok(#p6 == 5, "pack 'c5' length is 5")
  local v6 = string.unpack("c5", p6)
  ok(v6 == "abcde", "pack/unpack 'c5' round-trip")

  -- Multiple values in one pack
  local p7 = string.pack(">i2 >i2 >i2", 10, 20, 30)
  ok(#p7 == 6, "pack 3x>i2 length is 6")
  local x, y, z = string.unpack(">i2 >i2 >i2", p7)
  ok(x == 10 and y == 20 and z == 30, "pack/unpack 3x>i2 round-trip")
end

-- 8. string.packsize
ok(string.packsize(">i4") == 4, "packsize >i4 == 4")
ok(string.packsize("d") == 8,   "packsize d == 8")
ok(string.packsize("bBhH") == 6,"packsize bBhH == 6")

-- 9. string.rep with separator
ok(string.rep("ab", 3)       == "ababab", "rep without sep")
ok(string.rep("ab", 3, ",")  == "ab,ab,ab", "rep with sep comma")
ok(string.rep("x", 0)        == "", "rep 0 times == ''")

-- 10. string.reverse and string.sub
ok(string.reverse("hello") == "olleh", "reverse 'hello'")
ok(string.sub("hello", 2, 4) == "ell",  "sub(2,4)")
ok(string.sub("hello", -3)   == "llo",  "sub(-3) from end")
ok(string.sub("hello", 2, -2) == "ell", "sub(2,-2)")

-- 11. string.len and # operator
ok(string.len("hello") == 5, "string.len 'hello' == 5")
ok(#"hello" == 5,             "# 'hello' == 5")
ok(#"" == 0,                  "# '' == 0")

if fails == 0 then print("[+] PASS test_strings") os.exit(0) else os.exit(1) end
