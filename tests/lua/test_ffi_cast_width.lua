-- ffi.cast must truncate to the target C integer width (sign- or zero-extending
-- back per the target's signedness), exactly like a C cast; and a float->int
-- field write must truncate toward zero (not floor). Before the fix,
-- ffi.cast("unsigned int", -1) boxed 0xFFFFFFFFFFFFFFFF and a `-2.7` field
-- write stored -3.
local name = "test_ffi_cast_width"
if not ffi then print("[~] SKIP " .. name .. " (no ffi)") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. m) end end
local function num(cd) return tonumber(cd) end  -- tonumber hook understands cdata

-- width truncation on cast (narrowing)
ok(num(ffi.cast("unsigned int", -1)) == 4294967295,     "u32(-1) == 4294967295")
ok(num(ffi.cast("unsigned char", 300)) == 44,           "u8(300) == 44")
ok(num(ffi.cast("int", 0x1FFFFFFFF)) == -1,             "i32(0x1FFFFFFFF) == -1")
ok(num(ffi.cast("short", 0x10001)) == 1,                "i16(0x10001) == 1")
ok(num(ffi.cast("unsigned short", -1)) == 65535,        "u16(-1) == 65535")
ok(num(ffi.cast("signed char", 200)) == -56,            "i8(200) == -56")
ok(num(ffi.cast("int", 42)) == 42,                      "i32(42) == 42 (in-range identity)")
-- full 64-bit types are NOT truncated
ok(tostring(ffi.cast("uint64_t", -1)):find("18446744073709551615", 1, true) ~= nil,
   "u64(-1) keeps full width")
-- cast cdata -> narrower cdata also truncates
ok(num(ffi.cast("unsigned char", ffi.cast("int", 511))) == 255, "u8(i32(511)) == 255")

-- float -> int field write truncates toward zero
ffi.cdef("struct _cwt { int v; long long w; };")
local s = ffi.new("struct _cwt")
s.v = -2.7; ok(s.v == -2, "field -2.7 -> -2")
s.v = 2.9;  ok(s.v == 2,  "field 2.9 -> 2")
s.v = -0.9; ok(s.v == 0,  "field -0.9 -> 0")
s.w = -123.99; ok(s.w == -123, "field64 -123.99 -> -123")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
