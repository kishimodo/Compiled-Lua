-- tests/packages/test_zlib.lua : pure-Lua DEFLATE round-trip, focused on the
-- overlapping back-reference case (length > distance) that the inflater used to
-- corrupt -- e.g. deflate->inflate of "aaaa" produced "aa". M.deflate/M.inflate
-- always use the pure-Lua path, so this exercises the fix regardless of DLLs.
local zlib = require "zlib"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_zlib: " .. tostring(m)) end end

local function rt(s) return zlib.inflate(zlib.deflate(s, 6)) end

-- Overlapping runs (length > distance) -- the regressed path.
ok(rt("aaaa") == "aaaa",                                   "RLE run aaaa")
ok(rt(string.rep("a", 20)) == string.rep("a", 20),         "RLE run a x20")
ok(rt("abcabcabcabc") == "abcabcabcabc",                   "repeated substring abc")
ok(rt("hello hello hello hello") == "hello hello hello hello", "repeated words")
ok(rt(string.rep("xy", 100)) == string.rep("xy", 100),     "RLE run xy x100")

-- Edge / non-overlapping cases.
ok(rt("") == "",                                           "empty")
ok(rt("x") == "x",                                         "single byte")
ok(rt("the quick brown fox") == "the quick brown fox",     "literal text")

-- Larger mixed input.
local big = string.rep("The quick brown fox jumps. ", 60)
ok(rt(big) == big,                                         "repeated sentence x60")
local mixed = string.rep("ab", 1000) .. string.rep("Z", 500) .. "tail"
ok(rt(mixed) == mixed,                                     "mixed runs + tail")

-- gzip wrapper over RLE data (ISIZE/CRC would mismatch if inflate were wrong).
ok(zlib.gzip_decompress(zlib.gzip_compress(string.rep("a", 20), 6)) == string.rep("a", 20),
   "gzip round-trip of RLE run")
ok(zlib.zlib_decompress(zlib.zlib_compress(big, 6)) == big, "zlib-wrapped round-trip")

-- CRC/Adler sanity (known vectors).
ok(zlib.crc32("123456789") == 0xCBF43926,                  "crc32 of 123456789")

if fails == 0 then print("[+] PASS test_zlib") os.exit(0) else os.exit(1) end
