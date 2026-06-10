-- AOT differential: bitwise ops (BAND/BOR/BXOR/SHL/SHR + K + SHLI/SHRI) and
-- BNOT, including negative shift counts (which reverse direction in 5.4).
local a = 0xF0
local b = 0x0F
print(a & b, a | b, a ~ b, ~a)
print(a << 2, a >> 2, a << 4, a >> 4)

-- K-form bitwise (large constant)
print(a & 0xFFFF, a | 0xFF00, a ~ 0xAAAA)

-- immediate shifts SHLI / SHRI
print(1 << 8, 1024 >> 4, 1 << 0, 1024 >> 0)

-- negative shift = opposite direction
print(1 << (-1), 256 >> (-1))

-- chained bit math
local mask = 0
for k = 0, 7 do mask = mask | (1 << k) end
print(mask)
print(~0, ~0 >> 1, (~0) & 0xFF)
