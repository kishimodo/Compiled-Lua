-- tests/packages/test_varint.lua : LEB128 / protobuf varint round-trips.
local varint = require "varint"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_varint: " .. tostring(m)) end
end

-- ===== Unsigned varint battery =========================================
local uints = {
    0, 1, 2, 127, 128, 255, 256, 300, 16383, 16384, 65535, 65536,
    2097151, 2097152, 268435455, 268435456,
    4294967295, 4294967296, (2^53)//1, math.maxinteger,
}
for _, n in ipairs(uints) do
    local enc = varint.encode_uint(n)
    local d, np = varint.decode_uint(enc)
    ok(d == n, "uint round-trip " .. tostring(n))
    ok(np == #enc + 1, "uint next_pos correct for " .. tostring(n))
    ok(varint.size_uint(n) == #enc, "size_uint matches encode length for " .. tostring(n))
end

-- math.maxinteger (all bits as unsigned) and -1 bit pattern both fit 64-bit.
ok(varint.decode_uint(varint.encode_uint(math.maxinteger)) == math.maxinteger, "uint maxinteger")

-- ===== Signed (zigzag) varint battery ==================================
local sints = {
    0, 1, -1, 2, -2, 63, -64, 127, -128, 1000, -1000,
    2147483647, -2147483648, math.maxinteger, math.mininteger,
}
for _, n in ipairs(sints) do
    local enc = varint.encode_sint(n)
    local d, np = varint.decode_sint(enc)
    ok(d == n, "sint round-trip " .. tostring(n))
    ok(np == #enc + 1, "sint next_pos correct for " .. tostring(n))
end

-- ===== Streaming: concatenated varints decode positionally =============
local stream = varint.encode_uint(300) .. varint.encode_uint(1) .. varint.encode_uint(70000)
local v1, p1 = varint.decode_uint(stream, 1)
local v2, p2 = varint.decode_uint(stream, p1)
local v3 = varint.decode_uint(stream, p2)
ok(v1 == 300 and v2 == 1 and v3 == 70000, "positional decode of varint stream")

if fails == 0 then print("[+] PASS test_varint (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_varint (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
