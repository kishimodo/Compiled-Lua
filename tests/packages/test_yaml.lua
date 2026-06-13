-- tests/packages/test_yaml.lua : YAML 1.2 subset encode/decode round-trips.
local yaml = require "yaml"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_yaml: " .. tostring(m)) end
end
local function rt(v) return yaml.decode(yaml.encode(v)) end

-- ===== Scalar maps =====================================================
do
    local d = rt({ s = "hello", i = 42, neg = -7, f = 1.5, b1 = true, b0 = false })
    ok(d.s == "hello", "string scalar")
    ok(d.i == 42,      "integer scalar")
    ok(d.neg == -7,    "negative integer")
    ok(d.f == 1.5,     "float scalar")
    ok(d.b1 == true,   "boolean true")
    ok(d.b0 == false,  "boolean false")
end

-- ===== Integer battery =================================================
do
    local ints = { 0, 1, -1, 255, 256, 65535, 65536, 2147483647, -2147483648 }
    for _, n in ipairs(ints) do
        ok(rt({ v = n }).v == n, "integer round-trip " .. tostring(n))
    end
end

-- ===== Float battery ===================================================
do
    local floats = { 1.5, 0.25, 3.14, 0.1, -2.718281828, math.pi, 1e10, 1e-10, 65504.5 }
    for _, f in ipairs(floats) do
        ok(rt({ v = f }).v == f, "float round-trip " .. tostring(f))
    end
end

-- ===== Sequences =======================================================
do
    local d = rt({ list = {1, 2, 3}, strs = {"a", "b", "c"} })
    ok(#d.list == 3 and d.list[2] == 2, "integer sequence")
    ok(#d.strs == 3 and d.strs[3] == "c", "string sequence")
end

-- ===== Nested mappings =================================================
do
    local doc = {
        name = "clua-interp",
        version = 1,
        config = { host = "localhost", port = 8080, ratio = 0.5 },
        tags = {"x", "y", "z"},
    }
    local d = rt(doc)
    ok(d.name == "clua-interp",        "top-level string")
    ok(d.version == 1,           "top-level integer")
    ok(d.config.host == "localhost", "nested mapping string")
    ok(d.config.port == 8080,    "nested mapping integer")
    ok(d.config.ratio == 0.5,    "nested mapping float")
    ok(#d.tags == 3 and d.tags[1] == "x", "nested sequence")
end

-- ===== Multi-document stream ===========================================
do
    local s = yaml.encode_all({ {a = 1}, {b = 2}, {c = 3} })
    local docs = yaml.decode_all(s)
    ok(#docs == 3,        "decode_all returns 3 documents")
    ok(docs[1].a == 1,    "doc 1 value")
    ok(docs[2].b == 2,    "doc 2 value")
    ok(docs[3].c == 3,    "doc 3 value")
end

if fails == 0 then print("[+] PASS test_yaml (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_yaml (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
