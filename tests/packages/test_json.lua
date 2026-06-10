-- tests/packages/test_json.lua : json encode/decode round-trip. Compiled to a
-- standalone exe by the runner (which bundles the json package) and run.
local json = require "json"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_json: " .. m) end end

local obj = { name = "luavm", nums = { 1, 2, 3 }, ok = true }
local back = json.decode(json.encode(obj))
ok(back.name == "luavm",                  "string field round-trips")
ok(#back.nums == 3 and back.nums[2] == 2, "array field round-trips")
ok(back.ok == true,                       "boolean field round-trips")
ok(json.decode("[1,2,3]")[3] == 3,        "decode bare array")
ok(json.decode('{"a":1}').a == 1,         "decode object")

if fails == 0 then print("[+] PASS test_json") os.exit(0) else os.exit(1) end
