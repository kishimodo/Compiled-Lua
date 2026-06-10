local quoted_printable = require "quoted_printable"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_quoted_printable: " .. tostring(m)) end end

-- RFC 2045 6.7 rule 3: trailing whitespace at end of data must be encoded.
ok(quoted_printable.encode("abc ") == "abc=20", "trailing space -> " .. quoted_printable.encode("abc "))
ok(quoted_printable.encode("abc\t") == "abc=09", "trailing tab -> " .. quoted_printable.encode("abc\t"))
ok(quoted_printable.encode("abc") == "abc", "plain text unchanged -> " .. quoted_printable.encode("abc"))

-- Round-trip: decode(encode(x)) == x.
for _, x in ipairs({"abc ", "hello\tworld ", "plain"}) do
    local rt = quoted_printable.decode(quoted_printable.encode(x))
    ok(rt == x, "roundtrip for " .. string.format("%q", x) .. " -> " .. string.format("%q", rt))
end

if fails == 0 then print("[+] PASS test_quoted_printable") os.exit(0) else os.exit(1) end
