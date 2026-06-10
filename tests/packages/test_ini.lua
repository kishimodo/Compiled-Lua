-- tests/packages/test_ini.lua : ini list_separator must not drop/shift null
-- members. Compiled to a standalone exe by the runner (which bundles the ini
-- package) and run.
local ini = require "ini"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_ini: " .. tostring(m)) end end

-- Regression: a "null" (or empty) list member used to coerce to nil and, via
-- items[#items+1]=nil, collapse the array -- shifting later indices. The middle
-- null must be preserved as "" so length and positions stay correct.
local t = ini.decode('k = 1,null,3', {list_separator=','})
ok(type(t.k) == "table",  "k is a list/table")
ok(#t.k == 3,             "length is 3 (indices not shifted), got " .. tostring(#t.k))
ok(t.k[1] == 1,           "items[1] == 1, got " .. tostring(t.k[1]))
ok(t.k[2] == "",          "null member represented as empty string, got " .. tostring(t.k[2]))
ok(t.k[3] == 3,           "items[3] == 3, got " .. tostring(t.k[3]))

-- A trailing null must not shrink the array either.
local t2 = ini.decode('k = 1,2,null', {list_separator=','})
ok(#t2.k == 3,            "trailing null keeps length 3, got " .. tostring(#t2.k))
ok(t2.k[3] == "",         "trailing null member is empty string")

-- Sanity: ordinary lists still coerce element types.
local t3 = ini.decode('k = 1,two,true', {list_separator=','})
ok(t3.k[1] == 1 and t3.k[2] == "two" and t3.k[3] == true, "mixed list coerces element types")

-- Scalar "null" follows the documented mapping ("null" -> "" empty string), so
-- the key is preserved (it used to coerce to nil and drop the key entirely,
-- contradicting the header and the list path).
local s = ini.decode('a = null\nb = hello\nc = true')
ok(s.a == "",      "scalar null -> empty string (key preserved), got " .. tostring(s.a))
ok(s.b == "hello", "scalar string preserved")
ok(s.c == true,    "scalar bool preserved")

if fails == 0 then print("[+] PASS test_ini") os.exit(0) else os.exit(1) end
