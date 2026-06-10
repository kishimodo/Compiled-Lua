-- tests/packages/test_base16.lua : RFC 4648 Base16 (hex) round-trips.
local b16 = require "base16"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_base16: " .. tostring(m)) end
end

local function all_bytes()
    local t = {}
    for i = 0, 255 do t[i + 1] = string.char(i) end
    return table.concat(t)
end

-- Known vectors (RFC 4648 §10, "foobar" progression).
ok(b16.encode("") == "",             "encode empty")
ok(b16.encode("f") == "66",          "encode 'f'")
ok(b16.encode("fo") == "666F",       "encode 'fo'")
ok(b16.encode("foo") == "666F6F",    "encode 'foo'")
ok(b16.encode("foobar") == "666F6F626172", "encode 'foobar'")
ok(b16.decode("666F6F626172") == "foobar",  "decode 'foobar'")
-- Decode is case-insensitive.
ok(b16.decode("666f6f626172") == "foobar",  "decode lowercase")
-- Lowercase encode option.
ok(b16.encode("foo", false) == "666f6f", "encode lowercase via upper=false")

-- Round-trip battery.
local cases = { "", "a", "abc", "hello world", all_bytes(), "\0\0\0", "\255\254\253\0\1" }
for i, s in ipairs(cases) do
    ok(b16.decode(b16.encode(s)) == s, "round-trip case #" .. i .. " (len " .. #s .. ")")
end

if fails == 0 then print("[+] PASS test_base16 (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_base16 (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
