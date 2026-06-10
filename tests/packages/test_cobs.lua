-- tests/packages/test_cobs.lua : Consistent Overhead Byte Stuffing round-trips.
local cobs = require "cobs"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_cobs: " .. tostring(m)) end
end

local function all_bytes()
    local t = {}
    for i = 0, 255 do t[i + 1] = string.char(i) end
    return table.concat(t)
end

-- Invariant: encoded output must never contain a 0x00 byte.
local function no_zero(s)
    for i = 1, #s do if s:byte(i) == 0 then return false end end
    return true
end

-- Round-trip battery, with emphasis on zero bytes (COBS exists to remove them).
local cases = {
    "", "a", "abc", "hello world", all_bytes(),
    "\0", "\0\0\0", "\1\0\1\0", "x\0y\0z",
    ("\0"):rep(300),            -- long zero run (forces >254 overhead blocks)
    ("a"):rep(300),            -- long non-zero run (forces 0xFF marker blocks)
    ("\0a"):rep(200),          -- alternating
}
for i, s in ipairs(cases) do
    local enc = cobs.encode(s)
    ok(no_zero(enc), "encoded #" .. i .. " contains no 0x00 (len " .. #s .. ")")
    ok(cobs.decode(enc) == s, "round-trip #" .. i .. " (len " .. #s .. ")")
end

if fails == 0 then print("[+] PASS test_cobs (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_cobs (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
