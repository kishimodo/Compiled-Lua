-- FFI callbacks with more than 4 arguments. In the Win64 ABI, args 0-3 arrive
-- in registers and args 4+ on the stack ABOVE the 32-byte home/shadow space.
-- The callback stub used to read stack args from the home space (offset 0x10
-- instead of 0x30), so callbacks with >4 args saw garbage for args 4+. Each
-- test round-trips a Lua function -> callback stub -> invoked via the call thunk
-- (cb(...) on a CT_FUNCPTR cdata), exercising both ABI directions for >4 args.
local name = "test_ffi_callback_args"
if not ffi then print("[~] SKIP " .. name .. " (no ffi)") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. m) end end

-- 6 args: two of them land on the stack. Positional weights make every slot
-- distinguishable, so a misplaced arg changes the result.
ffi.cdef("typedef int (*Hex6)(int,int,int,int,int,int);")
local cb6 = ffi.cast("Hex6", function(a, b, c, d, e, f)
  return a + b * 10 + c * 100 + d * 1000 + e * 10000 + f * 100000
end)
ok(cb6(1, 2, 3, 4, 5, 6) == 654321, "6-arg: all args arrive (got " .. tostring(cb6(1,2,3,4,5,6)) .. ")")
ok(cb6(9, 8, 7, 6, 5, 4) == 456789, "6-arg: second call")
ok(cb6(0, 0, 0, 0, 0, 7) == 700000, "6-arg: only the last (stack) arg set")

-- 5 args: exactly one stack arg (the boundary case)
ffi.cdef("typedef int (*Pent)(int,int,int,int,int);")
local cb5 = ffi.cast("Pent", function(a, b, c, d, e) return a + b * 10 + c * 100 + d * 1000 + e * 10000 end)
ok(cb5(1, 2, 3, 4, 5) == 54321, "5-arg: the single stack arg arrives")
ok(cb5(0, 0, 0, 0, 9) == 90000, "5-arg: only the stack arg set")

-- 4 args: all in registers -- the common path must still work
ffi.cdef("typedef int (*Quad)(int,int,int,int);")
local cb4 = ffi.cast("Quad", function(a, b, c, d) return a + b * 10 + c * 100 + d * 1000 end)
ok(cb4(1, 2, 3, 4) == 4321, "4-arg: register args")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
