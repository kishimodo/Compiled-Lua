local querystring = require "querystring"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_querystring: " .. tostring(m)) end end

-- decode: percent + plus decoding against known-correct reference values
local d = querystring.decode("a=1&b=hello+world&c=%2B")
ok(d.a == "1", "decode a should be '1', got " .. tostring(d.a))
ok(d.b == "hello world", "'+' must decode to space, got " .. tostring(d.b))
ok(d.c == "+", "'%2B' must decode to '+', got " .. tostring(d.c))

-- "a+b" decodes to "a b"
local dp = querystring.decode("k=a+b")
ok(dp.k == "a b", "'a+b' must decode to 'a b', got " .. tostring(dp.k))

-- encode: known-correct output. Keys are sorted; space -> '+'; '+' (0x2B) -> '%2B'
ok(querystring.encode({ b = "hello world" }) == "b=hello+world", "space must encode to '+'")
ok(querystring.encode({ c = "+" }) == "c=%2B", "'+' must encode to '%2B'")
-- sorted-key stable output
ok(querystring.encode({ z = "1", a = "2" }) == "a=2&z=1", "keys must be sorted for stable output")
-- nil/false skipped
ok(querystring.encode({ a = "1", b = false }) == "a=1", "false value must be skipped")

-- round-trip: decode(encode(t)) == t for a representative table
local t = { name = "Jane Doe", city = "São", q = "a+b", empty = "" }
local round = querystring.decode(querystring.encode(t))
ok(round.name == t.name, "round-trip name mismatch: " .. tostring(round.name))
ok(round.city == t.city, "round-trip city (utf8) mismatch: " .. tostring(round.city))
ok(round.q == t.q, "round-trip q ('a+b') mismatch: " .. tostring(round.q))
ok(round.empty == t.empty, "round-trip empty mismatch: " .. tostring(round.empty))

-- array semantics: a=1&a=2 -> decode collapses duplicate key into a list table
local arr = querystring.decode("a=1&a=2")
ok(type(arr.a) == "table", "duplicate key 'a' must become a table")
ok(arr.a[1] == "1" and arr.a[2] == "2", "duplicate key values must be {'1','2'}")
-- encode of a table value reproduces the repeated key form
ok(querystring.encode({ a = { "1", "2" } }) == "a=1&a=2", "table value must encode as repeated key")

-- decode_array preserves order and duplicates as {key,value} pairs
local da = querystring.decode_array("a=1&a=2&b=3")
ok(#da == 3, "decode_array must keep 3 entries, got " .. tostring(#da))
ok(da[1][1] == "a" and da[1][2] == "1", "decode_array entry 1 must be {'a','1'}")
ok(da[2][1] == "a" and da[2][2] == "2", "decode_array entry 2 must be {'a','2'}")
ok(da[3][1] == "b" and da[3][2] == "3", "decode_array entry 3 must be {'b','3'}")

-- encode_array preserves input order (no sorting) and handles space encoding
ok(querystring.encode_array({ { "a", "1" }, { "a", "2" } }) == "a=1&a=2", "encode_array must preserve order/dupes")
ok(querystring.encode_array({ { "k", "x y" } }) == "k=x+y", "encode_array space must encode to '+'")

-- decode_array <-> encode_array round-trip preserves order and duplicates
local s = "a=1&a=2&b=hello+world"
ok(querystring.encode_array(querystring.decode_array(s)) == s, "array round-trip mismatch")

if fails == 0 then print("[+] PASS test_querystring") os.exit(0) else os.exit(1) end
