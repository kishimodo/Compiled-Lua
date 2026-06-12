-- tests/lua/test_cdata_eq_register.lua
-- Regression: `cdata ~= nil` (OP_EQK -- nil/constants fold into K) used as a
-- CALL ARGUMENT must not corrupt neighboring registers. The interpreter's
-- LuaJIT-compat OP_EQK patch called luaV_equalobj's __eq metamethod path
-- WITHOUT Protect, so luaT_callTMres wrote its frame at a stale L->top.p,
-- overwriting the live register that held the about-to-be-called function
-- ("attempt to call a boolean value"). Found 2026-06-12 when the migrated
-- suite first ran tests/lua under `luavm.exe -i`; fixed by running the
-- metamethod path under Protect exactly like OP_EQ.
local name = "test_cdata_eq_register"
if not ffi then print("[~] SKIP " .. name .. " (no ffi)") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. m) end end

-- the original corruption shape: comparison result as a direct call argument
local cd = ffi.new("int[2]")
ok(cd ~= nil, "array cdata ~= nil is true (and the call survives)")
ok(not (cd == nil), "array cdata == nil is false")

-- null and non-null pointer cdata vs the nil constant (the __eq compat path)
local pnull = ffi.cast("int *", 0)
ok(pnull == nil, "null pointer cdata == nil")
local cb = ffi.cast("int (*)(int, int)", function(a, b) return a + b end)
ok(cb ~= nil, "callback funcptr cdata ~= nil")
ok(cb(2, 3) == 5, "callback still round-trips after the comparisons")

-- neighboring locals survive a dense run of cdata-vs-nil comparisons
local a, b, c = 11, 22, 33
local r1, r2, r3 = (cd ~= nil), (pnull == nil), (cb ~= nil)
ok(a == 11 and b == 22 and c == 33, "locals intact after comparisons")
ok(r1 and r2 and r3, "comparison results all true")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
