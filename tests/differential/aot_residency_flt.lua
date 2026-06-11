-- M1 XMM float residency: proven-float slots live in xmm6..xmm10 across
-- qualified FORLOOP regions (entry-FLT gated, spilled value + FLT tag at the
-- fall-through exit). Stresses NaN/-0.0/inf payload preservation through
-- fill/spill, conditional writes, mixed int+float register files, and the
-- non-resident fallbacks.

-- float accumulator + int loop var: both files resident at once
local f, n = 0.0, 0
for i = 1, 1000 do f = f + 0.5 n = n + 1 end
print(f, n)                                -- 500.0 1000

-- several float residents, incl. read-only float bound and divisions
local a, b, c, half = 0.5, 100.0, 1.0, 2.0
for i = 1, 50 do
  a = a * 1.1
  b = b / half
  c = c + a - b
end
print(a, b, c)

-- NaN payload must survive fill/spill exactly
local nanacc = 0.0
for i = 1, 10 do
  if i == 5 then nanacc = nanacc + (0.0/0.0) else nanacc = nanacc + 1.0 end
end
print(nanacc ~= nanacc)                    -- true (NaN)

-- -0.0 sign preserved through residency
local nz = -(0.0)
for i = 1, 3 do nz = nz * 1.0 end
print(nz, 1.0 / nz)                        -- -0.0 -inf

-- inf accumulation
local big = 1e308
for i = 1, 3 do big = big * 2.0 end
print(big)                                 -- inf

-- conditional-write-only float slot with NON-float entry: entry gate must
-- exclude it (string survives)
local sx = "keep"
for i = 1, 5 do if i == 99 then sx = i + 0.5 end end
print(sx, type(sx))                        -- keep string

-- conditional-write float slot with FLOAT entry: eligible, both paths exact
local cf = 1.25
for i = 1, 8 do if i % 4 == 0 then cf = cf + 0.25 end end
print(cf)                                  -- 1.75

-- float compares against residents drive branches
local x, steps = 0.5, 0
for i = 1, 100 do
  if x < 25.0 then x = x * 1.5 steps = steps + 1 end
end
print(x >= 25.0, steps)

-- zero-trip float loop: no fill/spill, prior value intact
local z = 3.5
for i = 9, 1 do z = z + 1.0 end
print(z)                                   -- 3.5

-- spilled float read after the loop through every consumer shape
local acc = 0.0
for i = 1, 7 do acc = acc + 1.5 end
local t = { acc }
local g = function() return acc end
print(acc, t[1], g(), acc * 2.0)           -- 10.5 x3, 21.0

-- mixed: int slot and float slot interleaved every iteration
local isum, fsum = 0, 0.0
for i = 1, 200 do
  isum = isum + i
  fsum = fsum + 0.25
end
print(isum, fsum)                          -- 20100 50.0

-- more float candidates than xmm registers
local p1, p2, p3, p4, p5, p6 = 1.0, 2.0, 3.0, 4.0, 5.0, 6.0
for i = 1, 20 do
  p1 = p1 + 0.5 p2 = p2 + 1.0 p3 = p3 + 1.5
  p4 = p4 + 2.0 p5 = p5 + 2.5 p6 = p6 + 3.0
end
print(p1, p2, p3, p4, p5, p6)              -- 11.0 22.0 33.0 44.0 55.0 66.0

-- LOADF into a resident inside the loop (reassignment to a literal)
local r = 0.0
for i = 1, 6 do
  if i % 2 == 0 then r = 0.5 else r = r + 1.0 end
end
print(r)                                   -- 1.5

-- region rejected (helper in body): float values still exact
local h = 0.0
for i = 1, 3 do h = h + 0.1 print("h", h) end
print(h == 0.30000000000000004)

-- float MOVE between residents (local alias in body)
local src, dst = 2.5, 0.0
for i = 1, 10 do
  local tmp = src
  dst = dst + tmp
end
print(dst)                                 -- 25.0
print("done")
