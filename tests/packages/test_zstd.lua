-- tests/packages/test_zstd.lua : zstd compress/decompress round-trip over the
-- libzstd FFI wrapper. Compiled to a standalone exe by the runner.
--
-- zstd delegates to libzstd.dll; if the DLL is not on the search path the
-- package's own is_available() returns false and we SKIP. This also guards
-- the size_t-return regression: the one-shot funcs must be declared returning
-- 64-bit size_t (unsigned long long) on Win x64, and error sentinels must be
-- detected via ZSTD_isError -- not a 32-bit-truncating magnitude heuristic.
local ok_req, zstd = pcall(require, "zstd")
if not ok_req or not zstd.is_available() then
    print("[~] SKIP test_zstd") os.exit(0)
end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_zstd: " .. tostring(m)) end end

-- Round-trip a compressible string and recover it byte-for-byte.
local src = string.rep("the quick brown fox jumps over the lazy dog. ", 40)
local packed = zstd.compress(src, 3)
ok(type(packed) == "string" and #packed > 0, "compress returns non-empty bytes")
ok(#packed < #src, "compressible input actually shrinks")

-- A zstd frame starts with the magic number 0xFD2FB528 (little-endian on the
-- wire: bytes 28 B5 2F FD). This is a fixed value from the zstd format spec.
ok(packed:byte(1) == 0x28 and packed:byte(2) == 0xB5
   and packed:byte(3) == 0x2F and packed:byte(4) == 0xFD,
   "frame begins with the zstd magic number")

local back = zstd.decompress(packed)
ok(back == src, "decompress recovers the original exactly")

-- Binary-safe round-trip: NULs and high bytes survive.
local bin = ("\0\1\2\254\255z"):rep(200)
ok(zstd.decompress(zstd.compress(bin, 9)) == bin, "binary data round-trips")

-- Empty input round-trips to empty.
ok(zstd.decompress(zstd.compress("", 3)) == "", "empty string round-trips")

-- compress_bound must be a sane upper bound, not a 32-bit-truncated value.
local cb = zstd.compress_bound(1000000)
ok(type(cb) == "number" and cb >= 1000000, "compress_bound >= src size (no truncation)")

-- Error gating: decompressing a non-frame must raise (the size_t error
-- sentinel must reach ZSTD_isError, not be masked off by truncation).
local raised = not pcall(zstd.decompress, "this is not a zstd frame at all!!")
ok(raised, "decompress of garbage raises an error")

if fails == 0 then print("[+] PASS test_zstd") os.exit(0) else os.exit(1) end
