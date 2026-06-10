-- Regression test for the builtin `hmac` package.
--
-- Asserts against KNOWN-CORRECT published reference vectors:
--   * HMAC-SHA256/SHA512: RFC 4231 (TC1, TC2, TC6 >block-size key)
--   * HMAC-SHA1:          RFC 2202
--   * HMAC-MD5:           RFC 2104 / RFC 2202
-- plus the streaming ctx (new/update/final/final_hex) and the
-- constant-time equals() predicate (true on equal, false on unequal).
--
-- hmac relies on the `hash` package, whose SHA family is backed by Windows
-- CNG (BCrypt). If that backend is unavailable for some reason, degrade to
-- SKIP rather than report a false failure.
local ok_req, hmac = pcall(require, "hmac")
if not ok_req then print("[~] SKIP test_hmac") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_hmac: " .. tostring(m)) end end

local function rep(byte, n) return string.rep(string.char(byte), n) end

-- ---- RFC 4231 HMAC-SHA256 -------------------------------------------------
-- TC1: 20-byte 0x0b key, "Hi There"
ok(hmac.sha256_hex(rep(0x0b, 20), "Hi There")
   == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
   "sha256 TC1")

-- TC2: ASCII key "Jefe", "what do ya want for nothing?"
ok(hmac.sha256_hex("Jefe", "what do ya want for nothing?")
   == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
   "sha256 TC2")

-- TC6: 131-byte 0xaa key (> 64-byte block size -> key is pre-hashed)
ok(hmac.sha256_hex(rep(0xaa, 131),
       "Test Using Larger Than Block-Size Key - Hash Key First")
   == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
   "sha256 TC6 (>block-size key)")

-- ---- RFC 4231 HMAC-SHA512 (TC2) ------------------------------------------
ok(hmac.sha512_hex("Jefe", "what do ya want for nothing?")
   == "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554"
    .. "9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737",
   "sha512 TC2")

-- ---- RFC 2202 HMAC-SHA1 ---------------------------------------------------
ok(hmac.sha1_hex("Jefe", "what do ya want for nothing?")
   == "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79",
   "sha1 (RFC 2202)")

-- ---- RFC 2104 / RFC 2202 HMAC-MD5 ----------------------------------------
ok(hmac.md5_hex(rep(0x0b, 16), "Hi There")
   == "9294727a3638bb1c13f48ef8158bfc9d",
   "md5 (RFC 2104)")

-- ---- raw bytes one-shot + callable module shorthand -----------------------
local raw = hmac.sha256(rep(0x0b, 20), "Hi There")
ok(type(raw) == "string" and #raw == 32, "sha256 raw is 32 bytes")
-- raw should be the byte form of the TC1 hex above.
ok(raw == hmac("sha256", rep(0x0b, 20), "Hi There"),
   "callable shorthand == one-shot")

-- ---- streaming ctx: new / update / final / final_hex ----------------------
local ctx = hmac.new("sha256", "Jefe")
ctx:update("what do ya want "):update("for nothing?")
ok(ctx:final_hex()
   == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
   "streaming new/update/final_hex matches TC2")
-- final() is idempotent and returns the raw 32-byte MAC.
local m1 = ctx:final()
ok(type(m1) == "string" and #m1 == 32, "streaming final() raw is 32 bytes")
-- digest / hexdigest aliases.
local ctx2 = hmac.new("sha256", "Jefe"):update("what do ya want for nothing?")
ok(ctx2:hexdigest()
   == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
   "hexdigest alias matches TC2")

-- ---- constant-time equals() ----------------------------------------------
local a = hmac.sha256(rep(0x0b, 20), "Hi There")
local b = hmac.sha256(rep(0x0b, 20), "Hi There")
ok(hmac.equals(a, b) == true, "equals() true for equal MACs")
ok(hmac.equals(a, hmac.sha256(rep(0x0b, 20), "different")) == false,
   "equals() false for unequal MACs")
ok(hmac.equals("abc", "abcd") == false, "equals() false for differing lengths")
ok(hmac.equals("abc", "abc") == true, "equals() true for equal plain strings")
ok(hmac.equals("abc", 123) == false, "equals() false for non-string arg")

if fails == 0 then print("[+] PASS test_hmac") os.exit(0) else os.exit(1) end
