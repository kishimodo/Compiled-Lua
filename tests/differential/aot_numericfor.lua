-- AOT differential: numeric for-loops (up/down/step, zero-trip, float bounds,
-- single iteration, integer + float loop variables).
local s = 0
for i = 1, 10 do s = s + i end
print("up", s)

local d = 0
for i = 10, 1, -1 do d = d + i end
print("down", d)

local t = 0
for i = 0, 100, 5 do t = t + i end
print("step5", t)

-- zero-trip cases (must produce no iterations)
for i = 5, 1 do print("noprint asc") end
for i = 1, 5, -1 do print("noprint desc") end
print("zerotrip ok")

-- single iteration
for i = 7, 7 do print("single", i) end

-- float loop variable + float step
local fsum = 0.0
for x = 1.0, 3.0, 0.5 do fsum = fsum + x end
print("floatsum", fsum)

-- a float-bounded loop with integer-looking endpoints (track last via a local)
local last = 0.0
for x = 1.0, 4.0 do last = x end
print("floatbound", last)

-- negative float step
local g = 0.0
for x = 2.0, 0.0, -0.5 do g = g + x end
print("negfloat", g)
