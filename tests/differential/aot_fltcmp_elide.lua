-- M1 FLT compare elision: both-proven-float comparisons lower to bare ucomisd
-- (seta/setae give false-on-NaN; equality additionally requires PF=0). Probes
-- every elided form (reg-reg LT/LE/EQ, imm LTI/LEI/GTI/GEI), NaN/inf/-0.0
-- semantics, and the non-elided mixed-type fallbacks.

local function show(v) return tostring(v) end

-- reg-reg, both proven float
local a, b = 1.5, 2.5
print(a < b, b < a, a <= b, b <= a)        -- true false true false
print(a == b, a == 1.5, b == 2.5)          -- false true true
local c = a + 1.0                          -- 2.5, proven float
print(c == b, c < b, c <= b, b <= c)       -- true false true true

-- NaN: every comparison false (equality included), both directions
local nan = 0.0 / 0.0
print(nan < a, a < nan, nan <= a, a <= nan)  -- false x4
print(nan == nan, nan == a, a == nan)        -- false x3
print(nan < nan, nan <= nan)                 -- false false

-- signed zero: -0.0 == 0.0 is true, neither is less
local nz, pz = -(0.0), 0.0
print(nz == pz, nz < pz, pz < nz, nz <= pz, pz <= nz)  -- true false false true true

-- infinities
local inf = 1.0 / 0.0
print(a < inf, inf < a, -inf < a, inf <= inf, inf == inf)  -- true false true true true
print(-inf < inf, inf < -inf)                              -- true false

-- imm forms with proven-float reg: LTI/LEI/GTI/GEI (int imm and integral-float imm)
local f = 3.5
print(f < 4, f < 3, f <= 3, f <= 4)        -- true false false true
print(f > 3, f > 4, f >= 4, f >= 3)        -- true false false true
print(f < 4.0, f > 3.0, f <= 4.0, f >= 4.0)-- true true true false
print(nan < 1, nan > 1, nan <= 1, nan >= 1)-- false x4 (NaN vs imm)

-- precision boundary: 2^53 as float vs imm comparisons stay exact
local big = 9007199254740992.0
print(big > 100, big >= 100, big < 100)    -- true true false

-- float loop driven by elided compares (the hot pattern)
local x, steps = 0.5, 0
while x < 40.0 do x = x * 1.5 steps = steps + 1 end
print(x, steps)

-- repeat-until with float condition
local y = 100.0
repeat y = y / 2.0 until y <= 1.0
print(y)

-- mixed proofs (INT vs FLT) must fall to the checked/helper path and stay exact
local i3 = 3
print(i3 < 3.5, 3.5 < i3, i3 == 3.0, 2.0 == i3 - 1)  -- true false true true
print(1 < 1.5, 2 <= 2.0, 3 > 2.5)                    -- true true true

-- unknown types still take the complete helper (metamethods exact)
local omt = { __lt = function(p, q) return true end }
local t = setmetatable({}, omt)
print(t < 2.0)                              -- true (metamethod)
print("done")
