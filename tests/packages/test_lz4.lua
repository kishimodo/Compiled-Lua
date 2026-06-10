-- tests/packages/test_lz4.lua : LZ4 compress/decompress round-trips.
-- Compiled to a standalone exe by the runner (which bundles the lz4 package)
-- and run. Asserts vs known-correct reference values (XXH32 constants) and
-- exact-byte round-trips -- NOT the code's own output. Works with the pure-Lua
-- fallback; native liblz4.dll path is exercised transparently when present.
local ok_req, lz4 = pcall(require, "lz4")
if not ok_req then print("[~] SKIP test_lz4") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_lz4: " .. tostring(m)) end end

-- Frame-level round-trip: compress(x) then decompress must recover x exactly.
local function rt(s, label)
  local cok, comp = pcall(lz4.compress, s)
  ok(cok, label .. ": compress no error -> " .. tostring(comp))
  if not cok then return end
  local dok, back = pcall(lz4.decompress, comp)
  ok(dok, label .. ": decompress no error -> " .. tostring(back))
  if not dok then return end
  ok(back == s, label .. ": round-trip recovers exact bytes (got len " ..
     #back .. " want " .. #s .. ")")
end

rt("", "empty input")
rt("a", "single byte")
rt("hello", "tiny input (<12 bytes)")
rt("hello, world", "12-byte boundary")
rt(string.rep("A", 1000), "RLE run of 1000 identical bytes")
rt(string.rep("ab", 5000), "repeated 2-byte substring")
rt(("The quick brown fox jumps over the lazy dog. "):rep(50),
   "repeated sentence (long matches)")

-- Binary / all byte values (0..255), exact-byte fidelity incl. NUL.
local bin = {}
for i = 0, 255 do bin[i + 1] = string.char(i) end
bin = table.concat(bin)
rt(bin, "binary 0..255")
rt(bin:rep(20), "binary repeated")

-- Large input that forces multiple frame blocks (>64 KiB).
rt(string.rep("xyz123_", 20000), "large >64KiB compressible")

-- Incompressible (random) data must still round-trip exactly.
math.randomseed(42)
local rnd = {}
for i = 1, 5000 do rnd[i] = string.char(math.random(0, 255)) end
rt(table.concat(rnd), "random 5000 bytes (incompressible)")

-- decompress must reject non-frame input rather than silently mis-decode.
ok(not (pcall(lz4.decompress, "not an lz4 frame at all")),
   "decompress rejects non-frame garbage")

-- Raw block surface (block_compress / block_decompress).
local function brt(s, label)
  local comp = lz4.block_compress(s)
  local back = lz4.block_decompress(comp, #s + 1024)
  ok(back == s, label .. ": block round-trip (got " .. #back ..
     " want " .. #s .. ")")
end
brt("", "block empty")
brt("hello", "block tiny")
brt(string.rep("Z", 500), "block RLE run")
brt(string.rep("abcd", 1000), "block repeated substring")
brt(("pack my box with five dozen liquor jugs "):rep(30), "block sentence")
brt(bin, "block binary 0..255")

-- XXH32 against well-known published reference vectors (the LZ4 frame format
-- mandates XXH32; these are fixed constants, independent of this code).
ok(lz4.xxh32("", 0) == 0x02CC5D05,
   "xxh32('',0)==0x02CC5D05 got " .. string.format("0x%08X", lz4.xxh32("", 0)))
ok(lz4.xxh32("abc", 0) == 0x32D153FF,
   "xxh32('abc',0)==0x32D153FF got " .. string.format("0x%08X", lz4.xxh32("abc", 0)))

-- has_native must answer a boolean either way.
ok(type(lz4.has_native()) == "boolean", "has_native returns a boolean")

-- Streaming compressor/decompressor must round-trip across chunked updates.
local cstream = lz4.compressor()
cstream:update("foo")
cstream:update("bar")
cstream:update(string.rep("baz", 100))
local cdata = cstream:final()
local dstream = lz4.decompressor()
dstream:update(cdata)
ok(dstream:final() == "foobar" .. string.rep("baz", 100),
   "streaming compressor/decompressor round-trip")

if fails == 0 then print("[+] PASS test_lz4") os.exit(0) else os.exit(1) end
