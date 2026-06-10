-- AOT differential: all comparison flavors (EQ/LT/LE reg-reg, EQK, EQI/LTI/LEI/
-- GTI/GEI immediates), and/or/not, including NaN and int/float equality.
local a = 3
local b = 5
local f = 2.5
-- register-register comparisons
print(a < b, b < a, a <= a, b >= a, a == a, a ~= b)
-- mixed int/float comparisons
print(a < f, f < b, a == 3, a == 3.0, f == 2.5, f ~= 2.5)
-- immediate comparisons (EQI/LTI/LEI/GTI/GEI)
print(a == 3, a ~= 3, a < 10, a <= 3, a > 1, a >= 3)
print(b > 10, b >= 10, b < 1, b <= 1)
-- string equality / ordering (EQK + EQ + LT)
print("abc" == "abc", "abc" == "abd", "x" < "y", "y" <= "y")
-- NaN: every comparison with NaN is false; NaN ~= NaN is true
local nan = 0 / 0
print(nan == nan, nan ~= nan, nan < 1, nan > 1, nan <= nan)
-- and / or / not short-circuit
local x = 1
local y = nil
local z = false
print(x and 2, y and 2, x or 9, y or 9, z or 7)
print(not x, not y, not z, not not x)
print((a > 0) and "pos" or "neg", (a < 0) and "neg" or "nonneg")
