local url = require "url"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_url: " .. tostring(m)) end end

-- encode_component: percent-encodes everything outside unreserved.
-- " "=0x20->%20  "?"=0x3F->%3F  "&"=0x26->%26  "="=0x3D->%3D  "#"=0x23->%23
ok(url.encode_component(" ?&=#") == "%20%3F%26%3D%23", "encode_component reserved set")
-- unreserved chars must pass through untouched.
ok(url.encode_component("aZ0-._~") == "aZ0-._~", "encode_component unreserved untouched")
ok(url.decode_component("%20%3F%26%3D%23") == " ?&=#", "decode_component round-trip")

-- encode_query: form-encoding, space becomes '+'.
ok(url.encode_query("a b") == "a+b", "encode_query space -> '+'")
ok(url.encode_query("a&b=c") == "a%26b%3Dc", "encode_query reserved percent-encoded")
-- decode_query: '+' decodes to space.
ok(url.decode_query("a+b") == "a b", "decode_query '+' -> space")
ok(url.decode_query("a%20b") == "a b", "decode_query percent -> space")
ok(url.decode_query("a%26b%3Dc") == "a&b=c", "decode_query percent reserved")

-- parse(format(t)) preserves a full URL (scheme/host/path/query).
-- scheme is lowercased by parse, so use lowercase to guarantee round-trip.
local t = { scheme = "https", host = "example.com", port = 8080,
            path = "/a/b", query = "x=1&y=2", fragment = "frag", userinfo = "user" }
local s = url.format(t)
ok(s == "https://user@example.com:8080/a/b?x=1&y=2#frag", "format full URL")
local p = url.parse(s)
ok(p.scheme == "https", "parse scheme")
ok(p.userinfo == "user", "parse userinfo")
ok(p.host == "example.com", "parse host")
ok(p.port == 8080, "parse port")
ok(p.path == "/a/b", "parse path")
ok(p.query == "x=1&y=2", "parse query")
ok(p.fragment == "frag", "parse fragment")
-- and the full round-trip reproduces the original string.
ok(url.format(p) == s, "parse(format(t)) full round-trip")

-- A non-scheme colon must be rejected (left in the path, scheme stays nil).
-- "1http" before ':' starts with a digit, so it is not a valid scheme.
local nope = url.parse("1http://example.com/p")
ok(nope.scheme == nil, "non-scheme colon: scheme not set")
ok(nope.path == "1http://example.com/p", "non-scheme colon: colon kept in path")
ok(nope.host == nil, "non-scheme colon: no authority parsed")

if fails == 0 then print("[+] PASS test_url") os.exit(0) else os.exit(1) end
