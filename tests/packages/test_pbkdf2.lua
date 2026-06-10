-- tests/packages/test_pbkdf2.lua : key-derivation correctness against published
-- test vectors (RFC 6070 PBKDF2-HMAC-SHA1, RFC 7914 PBKDF2-HMAC-SHA256 + scrypt,
-- RFC 9106 Argon2id). The Argon2id p=4 vector also exercises the cross-lane
-- reference path that previously crashed for parallelism >= 2.
local pbkdf2 = require "pbkdf2"
local hash   = require "hash"
local fails = 0
local function H(s) return hash.to_hex(s) end
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_pbkdf2: " .. tostring(m)) end end
local function eq(label, got, exp) ok(got == exp, label .. " (got " .. tostring(got) .. ")") end

-- PBKDF2-HMAC-SHA1, RFC 6070.
eq("pbkdf2-sha1 c=1",    H(pbkdf2.derive("password", "salt", 1, 20, "sha1")),    "0c60c80f961f0e71f3a9b524af6012062fe037a6")
eq("pbkdf2-sha1 c=2",    H(pbkdf2.derive("password", "salt", 2, 20, "sha1")),    "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
eq("pbkdf2-sha1 c=4096", H(pbkdf2.derive("password", "salt", 4096, 20, "sha1")), "4b007901b765489abead49d926f721d065a429c1")

-- PBKDF2-HMAC-SHA256, RFC 7914 sec 11.
eq("pbkdf2-sha256 c=1",  H(pbkdf2.derive("passwd", "salt", 1, 64, "sha256")),
   "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")

-- scrypt, RFC 7914.
eq("scrypt empty N=16",  H(pbkdf2.scrypt("", "", 16, 1, 1, 64)),
   "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")

-- Argon2id, RFC 9106 sec 5.3 official vector (t=3, m=32, p=4, with secret + AD).
-- p=4 means this hits the multi-lane / cross-lane reference path that used to
-- crash with "attempt to index a nil value" before the ref-area-size fix.
eq("argon2id RFC9106 p=4",
   H(pbkdf2.argon2id(string.rep("\x01", 32), string.rep("\x02", 16), 3, 32, 4, 32,
                     string.rep("\x03", 8), string.rep("\x04", 12))),
   "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")

-- Argon2id parallelism >= 2 must not crash (the regressed case) and must be
-- deterministic. (m=32,p=2 is fast; value not pinned to a published vector.)
do
  local a = pbkdf2.argon2id("password", "saltsalt", 1, 32, 2, 32)
  local b = pbkdf2.argon2id("password", "saltsalt", 1, 32, 2, 32)
  ok(type(a) == "string" and #a == 32, "argon2id p=2 returns 32 bytes (no crash)")
  ok(a == b, "argon2id p=2 deterministic")
  ok(pbkdf2.argon2id("password", "saltsalt", 1, 32, 2, 32) ~=
     pbkdf2.argon2id("PASSWORD", "saltsalt", 1, 32, 2, 32), "argon2id sensitive to password")
end

if fails == 0 then print("[+] PASS test_pbkdf2") os.exit(0) else os.exit(1) end
