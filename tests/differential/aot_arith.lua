-- AOT differential: integer + float arithmetic, K-forms, immediates, wrapping,
-- floor-div / mod / pow, unary, length, concat, string->number coercion.
local a = 7
local b = 3
print(a + b, a - b, a * b, a / b, a // b, a % b, a ^ b)
print(-a, #"hello", "foo" .. "bar", a .. b)

-- K constants (large/float, exercises ADDK..POWK)
print(a + 100000, a - 100000, a * 100000, a / 4, a // 100000, a % 100000)
print(a + 0.25, a * 1.5, a - 2.5, a / 2.0)

-- immediate ADDI (small signed C)
local i = 10
print(i + 1, i + (-1), i + 100, i + (-100))

-- floor-div / mod sign rules (must match 5.4 exactly)
print(7 // 2, (-7) // 2, 7 // (-2), (-7) // (-2))
print(7 % 3, (-7) % 3, 7 % (-3), (-7) % (-3))

-- float arithmetic + mixed int/float
print(1.5 + 2.5, 10.0 / 4, 2.0 ^ 0.5, 3 * 2.0)

-- string -> number coercion in arithmetic
print("10" + 5, "3.5" * 2, "100" - "1", -"42")

-- integer wrapping (64-bit two's complement) using literal bounds (no math.*,
-- which would need GETFIELD — outside the Plan-1 op set)
local maxint = 0x7fffffffffffffff
print(maxint + 1)
print(maxint + 1 < 0)
