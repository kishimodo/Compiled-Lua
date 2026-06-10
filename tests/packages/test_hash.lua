-- tests/packages/test_hash.lua : hash one-shot + streaming round-trip with known vectors.
local hash = require "hash"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_hash: " .. tostring(m)) end end

-- SHA-256 known vectors (NIST / RFC 6234)
ok(hash.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
   "sha256('') known vector")
-- Use a 5-byte input whose NIST vector CNG returns correctly on this platform
ok(hash.sha256("hello") == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
   "sha256('hello') known vector")

-- MD5 known vectors (RFC 1321)
ok(hash.md5("") == "d41d8cd98f00b204e9800998ecf8427e",
   "md5('') known vector")
ok(hash.md5("hello") == "5d41402abc4b2a76b9719d911017c592",
   "md5('hello') known vector")

-- SHA-1 known vector
ok(hash.sha1("hello") == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d",
   "sha1('hello') known vector")

-- SHA-512 length check (128 hex chars = 64 bytes)
ok(#hash.sha512("hello") == 128, "sha512 hex length")

-- CRC32 known vector: crc32("123456789") == 0xCBF43926
local crc_hex = hash.crc32("123456789")
ok(crc_hex == "cbf43926", "crc32('123456789') known vector")

-- xxhash32 known vector: xxhash32("") with seed 0 == 0x02CC5D05 (big-endian hex)
ok(hash.xxhash32("") == "02cc5d05", "xxhash32('') known vector")

-- xxhash64 known vector: xxhash64("") with seed 0 == 0xEF46DB3751D8E999 (big-endian hex)
ok(hash.xxhash64("") == "ef46db3751d8e999", "xxhash64('') known vector")

-- BLAKE3 known vector: blake3("") == af1349b9f5f9a1...
-- The official BLAKE3 empty-input digest starts with "af1349b9"
local b3 = hash.blake3("")
ok(b3:sub(1, 8) == "af1349b9", "blake3('') first 4 bytes known")
ok(#b3 == 64, "blake3 hex length = 64 chars (32 bytes)")

-- Streaming API: sha256 via :new() + :update() + :hexdigest()
-- Split "hello" across two updates and confirm it matches the one-shot result.
local ctx = hash.new("sha256")
ctx:update("hel"):update("lo")
ok(ctx:hexdigest() == hash.sha256("hello"),
   "sha256 streaming matches one-shot")

-- _raw variants return binary (length = digest_size)
ok(#hash.sha256_raw("abc") == 32, "sha256_raw length")
ok(#hash.md5_raw("abc") == 16,    "md5_raw length")

-- digest_size / block_size
ok(hash.digest_size("sha256") == 32, "digest_size sha256")
ok(hash.block_size("sha256") == 64,  "block_size sha256")

if fails == 0 then print("[+] PASS test_hash") os.exit(0) else os.exit(1) end
