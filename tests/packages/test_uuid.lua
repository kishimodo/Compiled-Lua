-- tests/packages/test_uuid.lua : uuid generate / parse / format round-trip.
local uuid = require "uuid"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_uuid: " .. tostring(m)) end end

-- Pattern: 8-4-4-4-12 lowercase hex with hyphens (36 chars total)
local UUID_PAT = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

-- v4 format and length
local u4a = uuid.v4()
local u4b = uuid.v4()
ok(type(u4a) == "string",       "v4 returns string")
ok(#u4a == 36,                  "v4 length == 36")
ok(u4a:match(UUID_PAT) ~= nil,  "v4 matches UUID format")
ok(u4a ~= u4b,                  "two v4 calls differ")

-- v4 version nibble: byte 7 top nibble should be 4
local raw4 = uuid.parse_raw(u4a)
ok(#raw4 == 16,                        "parse_raw returns 16 bytes")
ok((raw4:byte(7) >> 4) == 4,           "v4 version nibble == 4")
-- variant byte: top 2 bits of byte 9 should be 10xx
ok((raw4:byte(9) & 0xC0) == 0x80,      "v4 variant bits == 10xx")

-- parse / format round-trip
local obj = uuid.parse(u4a)
ok(tostring(obj) == u4a,    "parse + tostring round-trips")
ok(obj:version() == 4,      "parsed object :version() == 4")
ok(obj:variant() == "rfc4122", "parsed object :variant() == 'rfc4122'")

-- format(raw) round-trip
ok(uuid.format(raw4) == u4a, "format(parse_raw(u)) == u")

-- v1 format + version nibble
local u1 = uuid.v1()
ok(#u1 == 36,                           "v1 length == 36")
ok(u1:match(UUID_PAT) ~= nil,           "v1 matches UUID format")
local raw1 = uuid.parse_raw(u1)
ok((raw1:byte(7) >> 4) == 1,            "v1 version nibble == 1")

-- v7 format + version nibble
local u7 = uuid.v7()
ok(#u7 == 36,                           "v7 length == 36")
local raw7 = uuid.parse_raw(u7)
ok((raw7:byte(7) >> 4) == 7,            "v7 version nibble == 7")

-- v3 name-based (MD5): deterministic
local ns = uuid.NAMESPACE_DNS
local uv3a = uuid.v3(ns, "www.example.com")
local uv3b = uuid.v3(ns, "www.example.com")
ok(uv3a == uv3b, "v3 is deterministic")
-- RFC 4122 reference: v3(DNS, "www.example.com") == 5df41881-3aed-3515-88a7-2f4a814cf09e
ok(uv3a == "5df41881-3aed-3515-88a7-2f4a814cf09e", "v3(DNS, www.example.com) known vector")

-- v5 name-based (SHA-1): deterministic; verify format and version nibble
local uv5a = uuid.v5(ns, "www.example.com")
local uv5b = uuid.v5(ns, "www.example.com")
ok(uv5a == uv5b, "v5 is deterministic")
ok(#uv5a == 36 and uv5a:match(UUID_PAT) ~= nil, "v5 UUID format valid")
local raw5 = uuid.parse_raw(uv5a)
ok((raw5:byte(7) >> 4) == 5, "v5 version nibble == 5")

-- ULID: 26 chars, Crockford base32
local ul = uuid.ulid()
ok(#ul == 26, "ulid length == 26")
ok(ul:match("^[0-9A-Z]+$") ~= nil, "ulid uses Crockford alphabet")

-- nanoid: default 21 chars
local nano = uuid.nanoid()
ok(#nano == 21, "nanoid default length == 21")
local nano12 = uuid.nanoid(12)
ok(#nano12 == 12, "nanoid(12) length == 12")

if fails == 0 then print("[+] PASS test_uuid") os.exit(0) else os.exit(1) end
