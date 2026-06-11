-- Spill-around observation points: helper-calling ops inside residency regions
-- spill all residents (value + tag) immediately before executing, making the
-- frame current for GC/errors/metamethods/relocation; registers stay
-- authoritative afterwards (no refill). Stresses every obs shape and the
-- frame-currency boundaries.

-- table store in a resident loop: SETI writes no frame slots
local t = {}
local s = 0
for i = 1, 100 do t[i] = i * 2 s = s + i end
print(s, t[1], t[100], #t)                 -- 5050 2 200 100

-- call in loop: results land in a dirtied slot; accumulators stay resident
local function double(x) return x * 2 end
local acc, dsum = 0, 0
for i = 1, 50 do
  local d = double(i)
  dsum = dsum + d
  acc = acc + 1
end
print(acc, dsum)                           -- 50 2550

-- helper on a cold path only: spills sit on the branched-around path
local hot, log = 0, {}
for i = 1, 1000 do
  hot = hot + i
  if i % 500 == 0 then log[#log + 1] = "tick" .. i end
end
print(hot, #log, log[1], log[2])           -- 500500 2 tick500 tick1000

-- error thrown FROM an observation point inside the loop: the frame must be
-- current at the throw (the spill ran before the helper)
local function boom()
  local n = 0
  for i = 1, 10 do
    n = n + i
    if i == 7 then error("n=" .. n) end
  end
  return n
end
print(pcall(boom))                         -- false ...n=28

-- early RETURN out of a resident loop (terminal observation: spill-before)
local function firstover(limit)
  local seen = 0
  for i = 1, 1000 do
    seen = seen + 1
    if i * i > limit then return i, seen end
  end
  return -1, seen
end
print(firstover(50))                       -- 8 8
print(firstover(10000000))                 -- -1 1000

-- metamethod fired from an obs op reads CURRENT values via its own paths
local side = {}
local mt = { __newindex = function(tb, k, v) rawset(tb, k, v) side[#side+1] = k end }
local wt = setmetatable({}, mt)
local widx = 0
for i = 1, 5 do widx = widx + 10 wt[i] = widx end
print(widx, wt[3], #side)                  -- 50 30 5

-- allocation pressure inside the loop (NEWTABLE obs): GC sees a current frame
local keep, count = nil, 0
for i = 1, 2000 do
  keep = { i, i + 1 }
  count = count + 1
end
print(count, keep[1], keep[2])             -- 2000 2000 2001

-- SELF method call in loop
local obj = { total = 0 }
function obj:add(v) self.total = self.total + v end
local calls = 0
for i = 1, 30 do obj:add(i) calls = calls + 1 end
print(obj.total, calls)                    -- 465 30

-- CONCAT + upvalue write from in-loop closure-free helpers
local pieces = 0
local str = ""
for i = 1, 4 do str = str .. i pieces = pieces + 1 end
print(str, pieces)                         -- 1234 4

-- float residents alongside obs ops
local fs, ft = 0.0, {}
for i = 1, 64 do
  fs = fs + 0.5
  ft[i] = fs
end
print(fs, ft[1], ft[64])                   -- 32.0 0.5 32.0

-- obs-cap rejection (7+ helper ops per iteration): plain paths stay exact
local r = 0
local g1, g2, g3, g4, g5, g6, g7 = {}, {}, {}, {}, {}, {}, {}
for i = 1, 10 do
  g1[i] = i g2[i] = i g3[i] = i g4[i] = i g5[i] = i g6[i] = i g7[i] = i
  r = r + i
end
print(r, g7[10])                           -- 55 10

-- mutation of a NON-resident local by call results each iteration
local last = nil
local cnt = 0
for i = 1, 20 do
  last = double(i)
  cnt = cnt + 1
end
print(last, cnt)                           -- 40 20
print("done")
