-- M1 float-K arith elision: ADDK/SUBK/MULK/DIVK with a proven-float R[B] and a
-- numeric constant (int K converted to double at compile time, same cast as the
-- runtime helper), plus the reg-reg DIV float/float elide. Compiled by aotc and
-- byte-diffed vs clua-interp.exe -i.

-- float accumulator + INT K (the common loop pattern -- previously helper every time)
local f = 0.5
for i = 1, 10 do f = f + 1 end
print(f)                                   -- 10.5
for i = 1, 3 do f = f - 2 end
print(f)                                   -- 4.5

-- float K on all four ops
local x = 1.5
x = x + 0.25  print(x)                     -- 1.75
x = x - 0.5   print(x)                     -- 1.25
x = x * 2.5   print(x)                     -- 3.125
x = x / 0.5   print(x)                     -- 6.25

-- DIVK by int K (result float, K converted)
local d = 7.0
print(d / 2)                               -- 3.5
for i = 1, 4 do d = d / 2 end
print(d)                                   -- 0.4375

-- division edge values: inf, -inf, nan must match the interpreter byte-for-byte
local z = 0.0
local pos, neg = 1.5, -1.5
print(pos / 0.0)                           -- inf
print(neg / 0.0)                           -- -inf
print(z / z)                               -- nan (reg-reg DIV, both proven float)
print(pos / z)                             -- inf  (reg-reg)
print(neg / z)                             -- -inf (reg-reg)

-- sign-of-zero precision: -0.0 arrives via UNM (proven float), then elided SUBK/ADDK
local nz = -(0.0)
print(nz)                                  -- -0.0
print(nz - 0.0)                            -- -0.0  (SUBK float K)
print(nz + 0.0)                            -- 0.0   (ADDK float K)
print(nz * 1.0)                            -- -0.0  (MULK float K)

-- negative-float K via folded unary minus
local m = 3.0
print(m * -1.0)                            -- -3.0
print(m + -0.5)                            -- 2.5

-- int K too large for int32 (k_int32 rejects; float arm converts with rounding,
-- identical to the runtime's cast_num): 2^53+1 rounds to 2^53
local big = 0.5
print(big + 9007199254740993)              -- 9.007199254741e+15
print(big * 4294967296)                    -- 2147483648.0 (2^32 K)

-- proven-INT B + float K must take the helper and still be exact
local i3 = 3
print(i3 + 1.5)                            -- 4.5
print(i3 / 2)                              -- 1.5 (DIVK with int B -> helper)

-- unknown-type B (function arg) + float K -> helper
local function g(v) return v * 0.5 end
print(g(9), g(9.0))                        -- 4.5  4.5

-- mixed kernel: loop-carried float through elided K-ops and reg-reg DIV
local acc = 0.5
local half = 2.0
for i = 1, 6 do
  acc = acc * 1.5 - 0.25 + acc / half
end
print(acc)

-- accumulate many: a float loop dominated by ADDK int-K
local s = 0.0
for i = 1, 100000 do s = s + 1 end
print(s)                                   -- 100000.0
