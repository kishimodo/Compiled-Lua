-- tests/lua/test_basics.lua : core Lua 5.4 semantics under the JIT host.
-- A behavioral test: asserts with a local helper, prints PASS, exits non-zero on
-- any failure (the runner classifies by the PASS/FAIL line + exit code).
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_basics: " .. m) end end

ok(1 + 2 == 3,                         "integer add")
ok(math.type(3) == "integer",          "integer subtype")
ok(math.type(3.0) == "float",          "float subtype")
ok(math.type(3 / 1) == "float",        "division yields float")
ok(7 // 2 == 3,                        "floor division")
ok(-7 // 2 == -4,                      "floor division rounds toward -inf")
ok(7 % 3 == 1,                         "modulo")
ok((-7) % 3 == 2,                      "modulo sign follows divisor")
ok((5 & 3) == 1,                       "bitwise and")
ok((5 | 2) == 7,                       "bitwise or")
ok((5 ~ 1) == 4,                       "bitwise xor")
ok((1 << 4) == 16,                     "shift left")
ok((256 >> 2) == 64,                   "shift right")
ok(("hi"):rep(3) == "hihihi",          "string rep")
ok(string.format("%d-%s", 5, "x") == "5-x", "string.format")
ok(tostring(10 // 1) == "10",          "integer prints without .0")
ok(#({ 1, 2, 3 }) == 3,                "table length")

local t = {}
for i = 1, 10 do t[i] = i * i end
ok(t[10] == 100,                       "numeric for loop fill")

local acc = 0
for _, v in ipairs({ 2, 4, 6 }) do acc = acc + v end
ok(acc == 12,                          "ipairs iteration")

if fails == 0 then print("[+] PASS test_basics") os.exit(0) else os.exit(1) end
