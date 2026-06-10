-- tests/lua/test_ffi_callback_methods.lua
-- LuaJIT-compat callback cdata methods: cb:free() releases the stub slot and
-- makes later calls through the cdata fail loudly; cb:set(fn) swaps the Lua
-- function behind the same native stub address. Added 2026-06-09 alongside
-- the CT_FUNCPTR __index methods (CAB-FFI-001 follow-on work).

local fails = 0
local function ok(c, m)
  if not c then fails = fails + 1; print("[-] FAIL test_ffi_callback_methods: " .. tostring(m)) end
end

-- ===== round-trip: Lua fn -> native stub -> dispatcher -> Lua fn =====
local cb = ffi.cast("int (*)(int, int)", function(a, b) return a + b end)
ok(cb ~= nil,                       "ffi.cast produced a callback cdata")
ok(cb(2, 3) == 5,                   "callback round-trip returns 5")

-- ===== cb:set(fn) swaps the target without changing the address =====
local addr_before = tostring(cb)
cb:set(function(a, b) return a * b end)
ok(cb(2, 3) == 6,                   "cb:set swapped the Lua function (2*3 == 6)")
ok(tostring(cb) == addr_before,     "cb:set kept the same stub address")

-- set rejects non-function arguments
ok(not pcall(function() cb:set(42) end),  "cb:set rejects a non-function")

-- ===== cb:free() =====
cb:free()
local ok_call, err_call = pcall(cb, 1, 1)
ok(not ok_call,                     "calling a freed callback raises")
ok(tostring(err_call):find("not resolved", 1, true) ~= nil,
                                    "freed-callback error mentions unresolved pointer")
ok(not pcall(function() cb:free() end),   "double free raises")
ok(not pcall(function() cb:set(function() end) end),
                                    "cb:set after free raises")

-- ===== slot reuse: freed slots are reusable =====
local cb2 = ffi.cast("int (*)(int)", function(x) return x - 1 end)
ok(cb2(10) == 9,                    "new callback works after a previous free")
cb2:free()

-- ===== methods on a plain cast'd native funcptr raise (not a callback) =====
ffi.cdef[[ void *GetModuleHandleA(const char *); ]]
local h = ffi.C.GetModuleHandleA("kernel32.dll")
local fp = ffi.cast("int (*)(void)", h)  -- bogus target, never called
ok(not pcall(function() fp:free() end),   "free() on non-callback funcptr raises")
ok(not pcall(function() fp:set(function() end) end),
                                    "set() on non-callback funcptr raises")

if fails == 0 then
  print("[+] PASS test_ffi_callback_methods")
  os.exit(0)
else
  os.exit(1)
end
