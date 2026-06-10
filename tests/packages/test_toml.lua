-- tests/packages/test_toml.lua : TOML 1.0 encode/decode round-trips.
local toml = require "toml"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_toml: " .. tostring(m)) end
end
local function rt(t) return toml.decode(toml.encode(t)) end

-- ===== Scalars =========================================================
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
        local d = rt({ v = n })
        ok(d.v == n, "integer round-trip " .. tostring(n))
    end
end

-- ===== Float battery ===================================================
do
    local floats = { 1.5, 0.25, 3.14, 0.1, -2.718281828, math.pi, 1e10, 1e-10, 65504.5 }
    for _, f in ipairs(floats) do
        local d = rt({ v = f })
        ok(d.v == f, "float round-trip " .. tostring(f))
    end
end

-- ===== Arrays ==========================================================
do
    local d = rt({ nums = {1, 2, 3}, strs = {"a", "b", "c"} })
    ok(#d.nums == 3 and d.nums[2] == 2, "integer array")
    ok(#d.strs == 3 and d.strs[3] == "c", "string array")
end

-- ===== Nested tables ===================================================
do
    local doc = {
        title = "demo",
        owner = { name = "luavm", level = 3 },
        server = { host = "localhost", port = 8080, ratio = 0.5 },
    }
    local d = rt(doc)
    ok(d.title == "demo",            "top-level string")
    ok(d.owner.name == "luavm",      "nested table string")
    ok(d.owner.level == 3,           "nested table integer")
    ok(d.server.port == 8080,        "deep nested integer")
    ok(d.server.ratio == 0.5,        "deep nested float")
end

-- ===== Strings with special chars ======================================
do
    local d = rt({ path = "C:\\\\temp", quote = 'he said "hi"', tab = "a\tb" })
    ok(d.path == "C:\\\\temp",       "backslashes round-trip")
    ok(d.quote == 'he said "hi"',    "embedded quotes round-trip")
    ok(d.tab == "a\tb",              "tab escape round-trips")
end

if fails == 0 then print("[+] PASS test_toml (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_toml (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
