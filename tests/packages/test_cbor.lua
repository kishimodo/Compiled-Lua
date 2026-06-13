-- tests/packages/test_cbor.lua : cbor encode/decode round-trip of nested structures.
local cbor = require "cbor"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_cbor: " .. tostring(m)) end end
-- Basic scalars
local function rt(v) return (cbor.decode(cbor.encode(v))) end

ok(rt(0)   == 0,     "round-trip 0")
ok(rt(1)   == 1,     "round-trip 1")
ok(rt(-1)  == -1,    "round-trip -1")
ok(rt(255) == 255,   "round-trip 255")
ok(rt(256) == 256,   "round-trip 256")
ok(rt(65536) == 65536, "round-trip 65536")
ok(rt(-100) == -100, "round-trip -100")

ok(rt(true)  == true,  "round-trip true")
ok(rt(false) == false, "round-trip false")

ok(rt("hello") == "hello", "round-trip string")
ok(rt("")      == "",      "round-trip empty string")

-- Float round-trip (binary64 via string.pack/unpack).
ok(rt(1.5)  == 1.5,  "round-trip float 1.5")
ok(rt(0.5)  == 0.5,  "round-trip float 0.5")
ok(rt(0.25) == 0.25, "round-trip float 0.25")
ok(rt(2.5)  == 2.5,  "round-trip float 2.5")
ok(rt(3.14) == 3.14, "round-trip float 3.14 (non-dyadic)")
ok(rt(0.1)  == 0.1,  "round-trip float 0.1 (non-dyadic)")
ok(rt(-2.718281828) == -2.718281828, "round-trip float -2.718281828")
ok(rt(math.pi) == math.pi, "round-trip float math.pi")
ok(rt(1e10) == 1e10, "round-trip float 1e10")
ok(rt(1e-10) == 1e-10, "round-trip float 1e-10")
ok(rt(65504.5) == 65504.5, "round-trip float 65504.5")

-- null sentinel
ok(rt(cbor.null) == cbor.null, "round-trip cbor.null")

-- Array
local arr = rt({10, 20, 30})
ok(#arr == 3 and arr[1] == 10 and arr[2] == 20 and arr[3] == 30,
   "round-trip array {10,20,30}")

-- Map (string keys)
local m = rt({ x = 1, y = 2 })
ok(m.x == 1 and m.y == 2, "round-trip map {x=1,y=2}")

-- Nested structure with mixed types
local nested = {
    name   = "clua-interp",
    count  = 42,
    active = true,
    tags   = {"a", "b", "c"},
    meta   = { version = 1, flag = false },
}
local back = rt(nested)
ok(back.name   == "clua-interp",   "nested: string field")
ok(back.count  == 42,        "nested: integer field")
ok(back.active == true,      "nested: boolean field")
ok(#back.tags  == 3,         "nested: array length")
ok(back.tags[2] == "b",      "nested: array element")
ok(back.meta.version == 1,   "nested: sub-map integer")
ok(back.meta.flag == false,  "nested: sub-map boolean")

-- bytes wrapper round-trip
local byt = cbor.bytes("rawbytes")
local byt_back = rt(byt)
ok(getmetatable(byt_back) ~= nil, "bytes metatype preserved")
ok(byt_back.data == "rawbytes",   "bytes data round-trips")

-- tag round-trip
local tagged = cbor.tag(42, "payload")
local tag_back = rt(tagged)
ok(tag_back.tag == 42,            "tag number round-trips")
ok(tag_back.value == "payload",   "tag value round-trips")

-- Decode positional offset: decode from middle of a larger buffer
local buf = cbor.encode(99) .. cbor.encode("end")
local v1, pos1 = cbor.decode(buf, 1)
local v2, _    = cbor.decode(buf, pos1)
ok(v1 == 99 and v2 == "end", "positional decode: two items in sequence")

if fails == 0 then print("[+] PASS test_cbor") os.exit(0) else os.exit(1) end
