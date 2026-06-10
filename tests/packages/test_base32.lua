-- tests/packages/test_base32.lua : RFC 4648 Base32 (standard + base32hex).
local b32 = require "base32"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_base32: " .. tostring(m)) end
end

local function all_bytes()
    local t = {}
    for i = 0, 255 do t[i + 1] = string.char(i) end
    return table.concat(t)
end

-- Known vectors (RFC 4648 §10).
ok(b32.encode("") == "",                 "encode empty")
ok(b32.encode("f") == "MY======",        "encode 'f'")
ok(b32.encode("fo") == "MZXQ====",       "encode 'fo'")
ok(b32.encode("foo") == "MZXW6===",      "encode 'foo'")
ok(b32.encode("foob") == "MZXW6YQ=",     "encode 'foob'")
ok(b32.encode("fooba") == "MZXW6YTB",    "encode 'fooba'")
ok(b32.encode("foobar") == "MZXW6YTBOI======", "encode 'foobar'")
ok(b32.decode("MZXW6YTBOI======") == "foobar",  "decode 'foobar'")

-- base32hex vectors (RFC 4648 §10).
ok(b32.encode("foobar", {hex=true}) == "CPNMUOJ1E8======", "encode hex 'foobar'")
ok(b32.decode("CPNMUOJ1E8======", {hex=true}) == "foobar", "decode hex 'foobar'")

-- Round-trip battery (standard + hex + no_padding).
local cases = { "", "a", "abc", "hello world", all_bytes(), "\0\0\0\0\0", "\255\254" }
for i, s in ipairs(cases) do
    ok(b32.decode(b32.encode(s)) == s, "std round-trip #" .. i .. " (len " .. #s .. ")")
    ok(b32.decode(b32.encode(s, {hex=true}), {hex=true}) == s, "hex round-trip #" .. i)
    ok(b32.decode(b32.encode(s, {no_padding=true})) == s, "no_padding round-trip #" .. i)
end

if fails == 0 then print("[+] PASS test_base32 (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_base32 (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
