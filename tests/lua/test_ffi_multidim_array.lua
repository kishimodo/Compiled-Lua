-- Multi-dimensional C arrays must nest first-dimension-outermost and be laid
-- out row-major, so a[i][j] addresses element (i*cols + j). The cdecl parser
-- used to wrap dimensions innermost-first, reversing the strides: for
-- `int a[2][3]`, a[0][2] aliased a[1][0]. Total size was unaffected, which is
-- why it slipped through. Covers both the field path (struct) and the
-- type-expression path (ffi.new("T[r][c]")).
local name = "test_ffi_multidim_array"
if not ffi then print("[~] SKIP " .. name .. " (no ffi)") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. m) end end

-- 2-D array as a struct field, with a sentinel to catch overruns
ffi.cdef("struct MD2 { int a[2][3]; int sentinel; };")
ok(ffi.sizeof("struct MD2") == 28, "sizeof int[2][3]+int == 28")
local m = ffi.new("struct MD2")
m.sentinel = 0x5A5A
for i = 0, 1 do for j = 0, 2 do m.a[i][j] = i * 10 + j end end
ok(m.a[0][0] == 0 and m.a[0][1] == 1 and m.a[0][2] == 2, "row 0 distinct: 0,1,2")
ok(m.a[1][0] == 10 and m.a[1][1] == 11 and m.a[1][2] == 12, "row 1 distinct: 10,11,12")
ok(m.sentinel == 0x5A5A, "no overrun into the trailing field")

-- row-major offset check via a flat byte view
local flat = ffi.cast("int*", m.a)
ok(flat[0] == 0 and flat[3] == 10, "row-major: a[1][0] is at flat index 3")

-- 3-D array
ffi.cdef("struct MD3 { int b[2][3][4]; };")
ok(ffi.sizeof("struct MD3") == 96, "sizeof int[2][3][4] == 96")
local t = ffi.new("struct MD3")
t.b[1][2][3] = 999
ok(t.b[1][2][3] == 999 and t.b[0][0][0] == 0, "3-D index writes the right cell")

-- type-expression path: ffi.new("int[2][3]")
local arr = ffi.new("int[2][3]")
arr[0][2] = 5
arr[1][0] = 7
ok(arr[0][2] == 5 and arr[1][0] == 7, "ffi.new('int[2][3]') indices are distinct")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
