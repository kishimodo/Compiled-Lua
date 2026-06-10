-- tests/packages/test_aes.lua : AES round-trips via Windows CNG (BCrypt).
-- Tests AES-128 (16-byte key), AES-192 (24-byte key), and AES-256 (32-byte key)
-- across GCM, CBC, and CTR modes.  Bug AES-002 (STATUS_INVALID_PARAMETER for
-- 16-byte keys) is now fixed: BCryptGenerateSymmetricKey receives raw key bytes.
local aes  = require "aes"
local name = "test_aes"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. tostring(m)) end end

local KEY16 = string.rep("\x42", 16)   -- AES-128
local KEY24 = string.rep("\x7f", 24)   -- AES-192
local KEY32 = string.rep("\x13", 32)   -- AES-256
local PT    = "Hello, AES world!!"
local PT2   = string.rep("x", 33)      -- odd length to exercise non-block-aligned paths

-- ===== GCM round-trips for all key sizes ==================================

-- AES-128 GCM
do
  local iv = aes.random_iv(12)
  local ct, tag = aes.encrypt("gcm", KEY16, PT, iv)
  ok(type(ct) == "string",                          "GCM-128 ciphertext is a string")
  ok(type(tag) == "string" and #tag == 16,          "GCM-128 tag is 16 bytes")
  ok(ct ~= PT,                                      "GCM-128 ciphertext differs from plaintext")
  ok(aes.decrypt("gcm", KEY16, ct, iv, nil, tag) == PT, "GCM-128 round-trip")
  ok(not pcall(aes.decrypt, "gcm", KEY16, ct, iv, nil, string.rep("\0", 16)),
     "GCM-128 rejects a wrong auth tag")
end

-- AES-192 GCM
do
  local iv = aes.random_iv(12)
  local ct, tag = aes.encrypt("gcm", KEY24, PT, iv)
  ok(type(ct) == "string",                          "GCM-192 ciphertext is a string")
  ok(type(tag) == "string" and #tag == 16,          "GCM-192 tag is 16 bytes")
  ok(ct ~= PT,                                      "GCM-192 ciphertext differs from plaintext")
  ok(aes.decrypt("gcm", KEY24, ct, iv, nil, tag) == PT, "GCM-192 round-trip")
  ok(not pcall(aes.decrypt, "gcm", KEY24, ct, iv, nil, string.rep("\0", 16)),
     "GCM-192 rejects a wrong auth tag")
end

-- AES-256 GCM (legacy positional API: encrypt(mode,key,pt,iv)->ct,tag)
do
  local iv_gcm = aes.random_iv(12)
  ok(type(iv_gcm) == "string" and #iv_gcm == 12,   "random_iv(12) returns 12 bytes")
  local ct_gcm, tag_gcm = aes.encrypt("gcm", KEY32, PT, iv_gcm)
  ok(type(ct_gcm) == "string",                     "GCM-256 ciphertext is a string")
  ok(type(tag_gcm) == "string" and #tag_gcm == 16, "GCM-256 tag is 16 bytes")
  ok(ct_gcm ~= PT,                                 "GCM-256 ciphertext differs from plaintext")
  ok(aes.decrypt("gcm", KEY32, ct_gcm, iv_gcm, nil, tag_gcm) == PT, "GCM-256 round-trip")
  ok(not pcall(aes.decrypt, "gcm", KEY32, ct_gcm, iv_gcm, nil, string.rep("\0", 16)),
     "GCM-256 rejects a wrong auth tag")
end

-- ===== CBC round-trips for all key sizes ==================================

do
  local iv = aes.random_iv(16)
  ok(type(iv) == "string" and #iv == 16,            "random_iv(16) returns 16 bytes")
  local ct = aes.encrypt("cbc", KEY16, PT, iv)
  ok(#ct % 16 == 0,  "CBC-128 ciphertext is block-aligned")
  ok(ct ~= PT,       "CBC-128 ciphertext differs from plaintext")
  ok(aes.decrypt("cbc", KEY16, ct, iv) == PT, "CBC-128 round-trip")
end

do
  local iv = aes.random_iv(16)
  local ct = aes.encrypt("cbc", KEY24, PT, iv)
  ok(#ct % 16 == 0,  "CBC-192 ciphertext is block-aligned")
  ok(aes.decrypt("cbc", KEY24, ct, iv) == PT, "CBC-192 round-trip")
end

do
  local iv = aes.random_iv(16)
  local ct = aes.encrypt("cbc", KEY32, PT, iv)
  ok(#ct % 16 == 0,  "CBC-256 ciphertext is block-aligned")
  ok(ct ~= PT,       "CBC-256 ciphertext differs from plaintext")
  ok(aes.decrypt("cbc", KEY32, ct, iv) == PT, "CBC-256 round-trip")
end

-- ===== CTR round-trips for all key sizes ==================================

do
  local iv = aes.random_iv(16)
  local ct = aes.encrypt("ctr", KEY16, PT2, iv)
  ok(#ct == #PT2,    "CTR-128 ciphertext same length as plaintext")
  ok(aes.decrypt("ctr", KEY16, ct, iv) == PT2, "CTR-128 round-trip")
end

do
  local iv = aes.random_iv(16)
  local ct = aes.encrypt("ctr", KEY24, PT2, iv)
  ok(#ct == #PT2,    "CTR-192 ciphertext same length as plaintext")
  ok(aes.decrypt("ctr", KEY24, ct, iv) == PT2, "CTR-192 round-trip")
end

do
  local iv = aes.random_iv(16)
  local ct = aes.encrypt("ctr", KEY32, PT, iv)
  ok(#ct == #PT,     "CTR-256 ciphertext same length as plaintext")
  ok(aes.decrypt("ctr", KEY32, ct, iv) == PT, "CTR-256 round-trip")
end

-- ===== PKCS#7 helpers (keyless) ==========================================

local padded = aes.pad_pkcs7("hello", 16)
ok(#padded == 16,                                   "pad_pkcs7 pads to block size")
ok(aes.unpad_pkcs7(padded, 16) == "hello",          "unpad_pkcs7 reverses pad")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
