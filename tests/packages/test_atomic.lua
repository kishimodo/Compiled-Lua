-- tests/packages/test_atomic.lua : atomic int / int64 / pointer / flag cells.
local ok_req, atomic = pcall(require, "atomic")
if not ok_req then print("[~] SKIP test_atomic (" .. tostring(atomic) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_atomic: " .. tostring(m)) end end

-- ===== API surface =====
ok(type(atomic.int)                  == "function", "atomic.int present")
ok(type(atomic.int64)                == "function", "atomic.int64 present")
ok(type(atomic.pointer)              == "function", "atomic.pointer present")
ok(type(atomic.flag)                 == "function", "atomic.flag present")
ok(type(atomic.fence)                == "function", "atomic.fence present")
ok(type(atomic.int_from_address)     == "function", "atomic.int_from_address present")
ok(type(atomic.int64_from_address)   == "function", "atomic.int64_from_address present")
ok(type(atomic.pointer_from_address) == "function", "atomic.pointer_from_address present")

-- ===== atomic.fence (uses FlushProcessWriteBuffers, not Interlocked*) =====
ok(pcall(atomic.fence) == true, "atomic.fence runs")

-- ===== int32 cell =====
local i = atomic.int(7)
ok(type(i)              == "table",    "int cell is table")
ok(type(i.get)          == "function", "int cell has get")
ok(type(i:address())    == "number",   "int cell address() is number")

ok(i:get() == 7, "int(7):get() == 7")
i:set(42)
ok(i:get() == 42, "int:set(42):get() == 42")
ok(i:swap(10) == 42, "int:swap(10) returns old (42)")
ok(i:get() == 10, "int:get() == 10 after swap")

local ok_, old = i:cas(10, 99)
ok(ok_ == true  and old == 10, "int:cas(10,99) succeeds, returns old 10")
local ok2, old2 = i:cas(10, 0)
ok(ok2 == false and old2 == 99, "int:cas(10,0) fails (current 99)")

local j = atomic.int(0)
ok(j:add(5) == 5,  "int(0):add(5) == 5 (post-add)")
ok(j:sub(2) == 3,  "int:sub(2) == 3 (post-sub)")
ok(j:inc()  == 4,  "int:inc() == 4")
ok(j:dec()  == 3,  "int:dec() == 3")
ok(j:or_(0xF0) == (3 | 0xF0),  "int:or_ returns post-or")
local j2 = atomic.int(0xFF)
ok(j2:and_(0x0F) == 0x0F, "int:and_ returns post-and")

-- int_from_address round-trip
local ref = atomic.int_from_address(i:address())
ok(ref:get() == i:get(), "int_from_address reads same value")

-- ===== int64 cell =====
local i6 = atomic.int64(1000000000000)
ok(i6:get() == 1000000000000, "int64 get round-trip")
i6:set(2000000000000)
ok(i6:get() == 2000000000000, "int64 set/get")
ok(i6:swap(1) == 2000000000000, "int64 swap returns old")
ok(i6:get() == 1, "int64 after swap")
ok(i6:add(9) == 10, "int64 add post-value")
ok(i6:inc()  == 11, "int64 inc")
ok(i6:dec()  == 10, "int64 dec")

-- ===== pointer cell =====
local p = atomic.pointer()
ok(type(p:address()) == "number", "pointer cell address is number")
-- get/set/swap with ffi null pointer
local null = ffi.cast("void *", 0)
ok(p:get() == null, "pointer cell starts null")
local arr = ffi.new("int[1]", 42)
p:set(arr)
ok(p:get() ~= null, "pointer set/get round-trip (not null)")
local old_p = p:swap(null)
ok(old_p ~= null and p:get() == null, "pointer swap")
local ok_cas, _ = p:cas(null, arr)
ok(ok_cas == true, "pointer CAS success")

-- ===== flag cell =====
local f = atomic.flag()
ok(f:get() == 0, "flag starts 0")
f:set(1)
ok(f:get() == 1, "flag set 1")
ok(f:test_and_set() == true, "test_and_set returns true when already 1")
f:clear()
ok(f:get() == 0, "clear sets 0")
ok(f:test_and_set() == false, "test_and_set returns false when was 0")
ok(f:get() == 1, "test_and_set leaves flag set")

if fails == 0 then print("[+] PASS test_atomic") os.exit(0) else os.exit(1) end
