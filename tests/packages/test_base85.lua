-- tests/packages/test_base85.lua : Base85 (RFC 1924 + Adobe Ascii85) round-trips.
local b85 = require "base85"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_base85: " .. tostring(m)) end
end

local function all_bytes()
    local t = {}
    for i = 0, 255 do t[i + 1] = string.char(i) end
    return table.concat(t)
end

-- Round-trip battery: default (rfc1924) and adobe variants.
local cases = {
    "", "a", "ab", "abc", "abcd", "abcde",
    "hello world", "Man ", "sure.", all_bytes(),
    "\0\0\0\0", "\255\255\255\255", "\0\1\2\3\4\5\6\7",
}
for i, s in ipairs(cases) do
    ok(b85.decode(b85.encode(s)) == s,        "rfc1924 round-trip #" .. i .. " (len " .. #s .. ")")
    ok(b85.decode(b85.encode(s, "adobe"), "adobe") == s, "adobe round-trip #" .. i)
end

-- Adobe 'z' shorthand: an all-zero 4-byte group encodes specially and must
-- decode back to four NUL bytes.
ok(b85.decode(b85.encode("\0\0\0\0", "adobe"), "adobe") == "\0\0\0\0",
   "adobe all-zero group round-trips")

if fails == 0 then print("[+] PASS test_base85 (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_base85 (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
