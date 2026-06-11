-- M1 loop-region register residency: proven-int slots live in R12-R15/RSI
-- across qualified FORLOOP regions (filled at entry, spilled value+tag at the
-- fall-through exit; zero-trip skips both). Stresses every qualification edge
-- and the spill/observation boundaries.

-- the marquee shape: accumulator + loop var resident
local s = 0
for i = 1, 1000 do s = s + i end
print(s)                                   -- 500500 (read AFTER the loop: spill)

-- multiple residents incl. read-only upper bound and three accumulators
local a, b, c, lim = 0, 0, 0, 10
for i = 1, 100 do
  a = a + 1
  b = b + i
  c = c + i * 2
  if i < lim then a = a + 1 end
end
print(a, b, c, lim)                        -- 109 5050 10100 10

-- zero-trip loop: fills/spills must be skipped, slot keeps its prior value
local z = 7
for i = 5, 1 do z = z + 100 end
print(z)                                   -- 7

-- nested loops: outer rejected (contains FORLOOP), inner resident
local n = 0
for i = 1, 50 do
  for j = 1, 50 do n = n + 1 end
end
print(n)                                   -- 2500

-- helper in body (print) rejects the region; loop still proven-int (bare path)
local h = 0
for i = 1, 3 do h = h + i print("h", h) end
print(h)                                   -- 6

-- break rejects the region; values still exact
local br = 0
for i = 1, 100 do br = br + i if i == 10 then break end end
print(br)                                  -- 55

-- wraparound semantics inside a (potentially) resident loop
local w = 0
for i = math.maxinteger - 2, math.maxinteger do w = w + 1 end
print(w)                                   -- 3

-- loop-var reassignment in body (int): control var is rewritten each iteration
local lv = 0
for i = 1, 5 do i = i + 100 lv = lv + i end
print(lv)                                  -- 530 (101+102+...+105)

-- accumulator retyped to float on one path: proofs collapse, region rejected,
-- behavior must stay exact through the checked/helper paths
local m = 0
for i = 1, 9 do
  if i % 2 == 0 then m = m + 0.5 else m = m + 1 end
end
print(m)                                   -- 7.0

-- more candidates than cache registers (cap at 5): spill set must be exact
local q1, q2, q3, q4, q5, q6, q7 = 1, 2, 3, 4, 5, 6, 7
for i = 1, 50 do
  q1 = q1 + 1 q2 = q2 + 2 q3 = q3 + 3
  q4 = q4 + 4 q5 = q5 + 5 q6 = q6 + 6 q7 = q7 + i
end
print(q1, q2, q3, q4, q5, q6, q7)          -- 51 102 153 204 255 306 1282

-- two sequential regions in one function; the second sees spilled values
local x = 0
for i = 1, 10 do x = x + i end
for i = 1, 10 do x = x + x end
print(x)                                   -- 55*1024 = 56320

-- bitwise residents
local bits = 0
for i = 1, 64 do bits = (bits << 1) ~ (i & 1) end
print(bits)

-- unknown limit: still an integer loop (bare FORLOOP), resident body
local function upto(k)
  local t = 0
  for i = 1, k do t = t + i end
  return t
end
print(upto(100), upto(0), upto(1))         -- 5050 0 1

-- comparisons against residents inside the region
local hits = 0
for i = 1, 200 do
  if i > 100 then hits = hits + 1 end
  if i == 150 then hits = hits + 10 end
end
print(hits)                                -- 110

-- float ops interleaved (slots dirty, never resident; region may still qualify)
local fsum, isum = 0.0, 0
for i = 1, 100 do
  fsum = fsum + 0.5
  isum = isum + 1
end
print(fsum, isum)                          -- 50.0 100

-- f + 1 / f - 1 float-ADDI elision (wave-2 bonus arm)
local fa = 0.5
for i = 1, 10 do fa = fa + 1 end
print(fa)                                  -- 10.5
print(fa - 1, fa + 0, -(0.0) - 0)          -- 9.5 10.5 0.0 (ADDI float arm, sign-of-zero)

-- CONDITIONAL-WRITE-ONLY slots (attack round 8): every in-region access is an
-- int-proven write behind a branch that never fires, but the slot enters the
-- loop holding a float/string/nil/boolean. Residency must NOT claim it (the
-- entry-INT gate) -- the exit spill would retag the raw payload as integer.
local cf = 1.5
for i = 1, 5 do if i == 99 then cf = i end end
print(cf, math.type(cf))                   -- 1.5 float
local cs = "hello"
for i = 1, 5 do if i == 99 then cs = i end end
print(cs, type(cs), cs == "hello")         -- hello string true
local cn = nil
for i = 1, 5 do if i == 99 then cn = i end end
print(cn, type(cn))                        -- nil nil
local cb = true
for i = 1, 4 do if i == 99 then cb = i end end
print(cb, type(cb))                        -- true boolean
local best, threshold = 0.0, 1000
for i = 1, 10 do if i > threshold then best = i end end
print(best, math.type(best), best + 0.5)   -- 0.0 float 0.5
-- and the taken-branch variant must still update exactly
local hit = 2.5
for i = 1, 5 do if i == 3 then hit = i end end
print(hit, math.type(hit))                 -- 3 integer
-- conditional write with int entry: eligible for residency, must stay exact
local ci = 7
for i = 1, 5 do if i == 4 then ci = ci + i end end
print(ci)                                  -- 11
print("done")
