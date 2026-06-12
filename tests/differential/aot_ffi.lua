-- aot_ffi.lua - the ffi global works in compiled programs when referenced
-- (the resolve scan links the Clua_OpenFfi anchor). v1 convention: ffi is a
-- GLOBAL, not a require-able module, in both engines.
local ffi = _G.ffi
print(type(ffi), type(ffi.cdef), type(ffi.new))
ffi.cdef("typedef struct { int x; int y; } aotffi_pt;")
local p = ffi.new("aotffi_pt")
p.x = 7
p.y = 35
print(p.x + p.y)
print(tonumber(ffi.cast("unsigned int", -1)))
print(ffi.sizeof("aotffi_pt"))
