-- tests/packages/test_properties.lua : Java .properties decode/encode.
-- Asserts against known-correct reference values + round-trips (not the code's
-- own output). Compiled to a standalone exe by the runner (which bundles the
-- properties package) and run.
local ok_req, properties = pcall(require, "properties")
if not ok_req then print("[~] SKIP test_properties") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_properties: " .. tostring(m)) end end

-- ===== decode: separators =====
local d = properties.decode("a=1\nb:2\nc 3\n")
ok(d.a == "1", "= separator")
ok(d.b == "2", ": separator")
ok(d.c == "3", "whitespace separator")

-- ===== decode: leading ws stripped, trailing preserved =====
local d2 = properties.decode("k =   val  \n")
ok(d2.k == "val  ", "leading value ws stripped, trailing preserved")

-- ===== decode: comments skipped (# and !) =====
local d3 = properties.decode("# comment\n! also comment\n   # indented comment\nreal=yes\n")
ok(d3.real == "yes", "real key after comments")
ok(d3["# comment"] == nil, "# comment line not a key")
ok(d3["! also comment"] == nil, "! comment line not a key")

-- ===== decode: spaced key via escaped space (a\ b = c) =====
local d4 = properties.decode("a\\ b = c\n")
ok(d4["a b"] == "c", "escaped space in key (a\\ b)")
ok(d4["a"] == nil, "escaped space did not split key")

-- ===== decode: escaped separator chars in key =====
local d5 = properties.decode("a\\=b=c\nx\\:y:z\n")
ok(d5["a=b"] == "c", "escaped = in key")
ok(d5["x:y"] == "z", "escaped : in key")

-- ===== decode: escape sequences in value =====
local d6 = properties.decode("k=line1\\nline2\\ttab\n")
ok(d6.k == "line1\nline2\ttab", "\\n and \\t escapes decode")

-- ===== decode: \\uXXXX unicode escape =====
local d7 = properties.decode("k=\\u0041\\u00e9\n")
ok(d7.k == "A" .. utf8.char(0xE9), "\\uXXXX unicode escape decodes")

-- ===== decode: line continuation (trailing backslash) =====
local d8 = properties.decode("k=one\\\n   two\n")
ok(d8.k == "onetwo", "backslash line continuation joins (leading ws of next stripped)")

-- ===== decode: duplicate keys, later wins =====
local d9 = properties.decode("k=first\nk=second\n")
ok(d9.k == "second", "duplicate key: later wins")

-- ===== decode: key with no separator -> empty value =====
local d10 = properties.decode("lonely\n")
ok(d10.lonely == "", "key with no separator -> empty string value")

-- ===== decode: CRLF and CR normalized =====
local d11 = properties.decode("a=1\r\nb=2\rc=3\n")
ok(d11.a == "1" and d11.b == "2" and d11.c == "3", "CRLF and CR normalized to LF")

-- ===== decode: BOM stripped =====
local d12 = properties.decode("\xEF\xBB\xBFk=v\n")
ok(d12.k == "v", "leading UTF-8 BOM stripped")

-- ===== encode: basic + sorted default + trailing newline =====
local e1 = properties.encode({ b = "2", a = "1" })
ok(e1 == "a=1\nb=2\n", "encode sorts keys by default, = sep, trailing newline")

-- ===== encode: separator option =====
local e2 = properties.encode({ k = "v" }, { separator = ":" })
ok(e2 == "k:v\n", "encode with : separator")

-- ===== encode: bad separator errors =====
local bad_ok = pcall(properties.encode, { k = "v" }, { separator = "|" })
ok(not bad_ok, "bad separator raises error")

-- ===== encode: special chars in key escaped =====
local e3 = properties.encode({ ["a b"] = "x" })
ok(e3 == "a\\ b=x\n", "space in key escaped on encode")
local e4 = properties.encode({ ["a=b"] = "x" })
ok(e4 == "a\\=b=x\n", "= in key escaped on encode")

-- ===== encode: leading space in value escaped, special chars escaped =====
local e5 = properties.encode({ k = " lead\tval" })
ok(e5 == "k=\\ lead\\tval\n", "leading space + tab in value escaped")

-- ===== round-trip: decode(encode(t)) == t =====
local function rt(t)
    local back = properties.decode(properties.encode(t))
    for k, v in pairs(t) do if back[k] ~= v then return false, k end end
    for k in pairs(back) do if t[k] == nil then return false, k end end
    return true
end
ok(rt({ name = "luavm", ["spaced key"] = "spaced val ", url = "http://x:80/p" }),
   "round-trip: spaced keys, : in value, trailing ws")
ok(rt({ ["a:b"] = "c", ["d=e"] = "f", ["#h"] = "g", ["!i"] = "j" }),
   "round-trip: sep/comment chars in keys")
ok(rt({ multi = "line1\nline2\twith\ttabs", back = "a\\b" }),
   "round-trip: newlines, tabs, backslash in value")
ok(rt({ empty = "" }), "round-trip: empty value")

if fails == 0 then print("[+] PASS test_properties") os.exit(0) else os.exit(1) end
