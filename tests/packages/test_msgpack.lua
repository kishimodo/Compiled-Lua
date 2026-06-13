-- tests/packages/test_msgpack.lua : MessagePack pack/unpack round-trip.
--
-- The float battery here is exactly what catches the historic r_f64 decode
-- corruption (mp.unpack(mp.pack(3.14)) used to return 6.96...).
local mp = require "msgpack"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_msgpack: " .. tostring(m)) end
end
local function rt(v) return (mp.unpack(mp.pack(v))) end

-- ===== Integer battery =================================================
local ints = {
    0, 1, -1, 31, 32, -32, -33, 127, 128, 255, 256, 65535, 65536,
    16777215, 16777216, 4294967295, 4294967296,
    2147483647, -2147483648, 2147483648, -2147483649,
    (2^53)//1, math.maxinteger, math.mininteger,
}
for _, n in ipairs(ints) do
    ok(rt(n) == n, "int round-trip " .. tostring(n))
end

-- ===== Float battery (the regression guard) ============================
local floats = {
    1.5, 0.25, 2.5, 0.5, 3.14, 0.1, -2.718281828, math.pi,
    1e10, 1e-10, 65504.5, 1.0/3.0, -0.0, 123456.789,
}
for _, f in ipairs(floats) do
    local back = rt(f)
    ok(back == f, "float round-trip " .. tostring(f))
end
-- explicit non-integer float must round-trip exactly, not get truncated
ok(rt(3.14) == 3.14, "float 3.14 exact (r_f64 regression guard)")
ok(rt(0.1) == 0.1,   "float 0.1 exact")
ok(rt(math.pi) == math.pi, "float math.pi exact")

-- Special float values
ok(rt(math.huge) == math.huge,   "float +inf")
ok(rt(-math.huge) == -math.huge, "float -inf")
local nan = rt(0/0); ok(nan ~= nan, "float NaN round-trips as NaN")

-- ===== Strings =========================================================
local function all_bytes()
    local t = {}
    for i = 0, 255 do t[i + 1] = string.char(i) end
    return table.concat(t)
end
ok(rt("") == "",        "empty string")
ok(rt("abc") == "abc",  "short string")
ok(rt(all_bytes()) == all_bytes(), "all 256 byte values")
ok(rt(("x"):rep(40)) == ("x"):rep(40),     "str8 length")
ok(rt(("y"):rep(40000)) == ("y"):rep(40000), "str16 length")
ok(rt("héllo \xE2\x9C\x93") == "héllo \xE2\x9C\x93", "utf-8 string")

-- ===== Booleans / nil ==================================================
ok(rt(true) == true,   "boolean true")
ok(rt(false) == false, "boolean false")
ok(rt(mp.nil_value) == nil, "explicit nil sentinel decodes to nil")

-- ===== Arrays ==========================================================
local a = rt({10, 20, 30})
ok(#a == 3 and a[1] == 10 and a[2] == 20 and a[3] == 30, "array {10,20,30}")
local big = {}; for i = 1, 100 do big[i] = i end
local bb = rt(big); ok(#bb == 100 and bb[100] == 100, "array16 length 100")
ok(#rt({}) == 0, "empty array")

-- ===== Maps ============================================================
local m = rt({ x = 1, y = 2, z = "three" })
ok(m.x == 1 and m.y == 2 and m.z == "three", "map string keys")

-- ===== Nested + mixed (with floats) ====================================
local doc = {
    name = "clua-interp", count = 42, ratio = 3.14, active = true,
    tags = {"a", "b", "c"},
    meta = { version = 1.5, flag = false, deep = { x = 0.1 } },
}
local d = rt(doc)
ok(d.name == "clua-interp",        "nested string")
ok(d.count == 42,            "nested int")
ok(d.ratio == 3.14,          "nested float (regression guard)")
ok(d.active == true,         "nested bool")
ok(#d.tags == 3 and d.tags[2] == "b", "nested array")
ok(d.meta.version == 1.5,    "nested sub-map float")
ok(d.meta.deep.x == 0.1,     "deeply nested float")

-- ===== Positional unpack ===============================================
local buf = mp.pack(99) .. mp.pack("end")
local v1, p1 = mp.unpack(buf, 1)
local v2 = mp.unpack(buf, p1)
ok(v1 == 99 and v2 == "end", "positional unpack of two items")

-- ===== unpack_all ======================================================
local stream = mp.pack(1) .. mp.pack(2.5) .. mp.pack("z")
local vals = mp.unpack_all(stream)
ok(#vals == 3 and vals[1] == 1 and vals[2] == 2.5 and vals[3] == "z", "unpack_all")

if fails == 0 then print("[+] PASS test_msgpack (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_msgpack (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
