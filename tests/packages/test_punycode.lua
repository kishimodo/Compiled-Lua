-- tests/packages/test_punycode.lua : RFC 3492 encode/decode round-trips.
--
-- Guards the all-ASCII delimiter fix: encode("hello") must emit the trailing
-- '-' delimiter so decode("hello-") recovers "hello". Vectors below are from
-- RFC 3492 section 7.1 (where determinate) plus general round-trips.
local puny = require "punycode"
local fails, asserts = 0, 0
local function ok(c, m)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[-] FAIL test_punycode: " .. tostring(m)) end
end

-- Helper: build a UTF-8 string from code points.
local function u(...)
    local cps = {...}
    local out = {}
    for _, cp in ipairs(cps) do
        if cp < 0x80 then out[#out+1] = string.char(cp)
        elseif cp < 0x800 then
            out[#out+1] = string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
        elseif cp < 0x10000 then
            out[#out+1] = string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
        else
            out[#out+1] = string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
                                      0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
        end
    end
    return table.concat(out)
end

-- ===== Known RFC 3492 vectors ==========================================
-- "bücher"  -> "bcher-kva"   (b, c, h, e, r are basic; ü follows)
local bucher = u(0x62, 0xFC, 0x63, 0x68, 0x65, 0x72)
ok(puny.encode(bucher) == "bcher-kva", "RFC vector: bucher -> bcher-kva")
ok(puny.decode("bcher-kva") == bucher,  "RFC vector: bcher-kva -> bucher")

-- "München" -> "Mnchen-3ya"
local munchen = u(0x4D, 0xFC, 0x6E, 0x63, 0x68, 0x65, 0x6E)
ok(puny.encode(munchen) == "Mnchen-3ya", "RFC vector: Munchen -> Mnchen-3ya")
ok(puny.decode("Mnchen-3ya") == munchen,  "RFC vector: Mnchen-3ya -> Munchen")

-- ===== All-ASCII delimiter behaviour (the bug under test) ==============
ok(puny.encode("hello") == "hello-", "all-ASCII encode emits trailing delimiter")
ok(puny.decode("hello-") == "hello", "all-ASCII decode strips trailing delimiter")
ok(puny.decode(puny.encode("hello")) == "hello", "all-ASCII round-trip 'hello'")
ok(puny.decode(puny.encode("a")) == "a",     "all-ASCII round-trip 'a'")
ok(puny.decode(puny.encode("abc123")) == "abc123", "all-ASCII round-trip 'abc123'")

-- ===== Round-trip battery (ASCII / mixed / all-Unicode) ================
local cases = {
    "hello",
    "test-label",                          -- ASCII already containing a hyphen
    u(0xE4),                               -- all-Unicode: "ä"
    u(0xE4, 0xF6, 0xFC),                   -- all-Unicode: "äöü"
    u(0x61, 0x62, 0xE9),                   -- mixed: "abé"
    munchen,
    bucher,
    u(0x4E2D, 0x6587),                     -- all-Unicode CJK: "中文"
    u(0x68, 0x69, 0x4E2D, 0x6587),         -- mixed: "hi中文"
    u(0x1F600),                            -- astral: emoji
}
for i, c in ipairs(cases) do
    ok(puny.decode(puny.encode(c)) == c, "round-trip case #" .. i)
end

-- ===== to_ascii / to_unicode domain helpers ============================
ok(puny.to_ascii("plain.example.com") == "plain.example.com",
   "to_ascii passes all-ASCII domain through verbatim")
local idn = munchen .. ".de"
ok(puny.to_ascii(idn) == "xn--Mnchen-3ya.de", "to_ascii adds xn-- for IDN label")
ok(puny.to_unicode("xn--Mnchen-3ya.de") == idn, "to_unicode resolves xn-- label")
ok(puny.to_unicode(puny.to_ascii(idn)) == idn, "to_ascii/to_unicode round-trip")

if fails == 0 then print("[+] PASS test_punycode (" .. asserts .. " asserts)") os.exit(0)
else print("[-] FAIL test_punycode (" .. fails .. "/" .. asserts .. ")") os.exit(1) end
