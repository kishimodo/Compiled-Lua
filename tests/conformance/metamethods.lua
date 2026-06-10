-- metamethods.lua : every Lua 5.4 metamethod -- arithmetic, bitwise, comparison,
-- __index/__newindex (function+table+chain), __concat, __len, __call, __tostring,
-- __name, __pairs removed in 5.4 (not tested). Deterministic; JIT and -i must agree.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- A "vector" type exercising the full arithmetic/bitwise/comparison metamethod set.
local Vec = {}
Vec.__index = Vec
local function V(n) return setmetatable({n = n}, Vec) end
local function bin(f) return function(a, b)
  local an = type(a) == "table" and a.n or a
  local bn = type(b) == "table" and b.n or b
  return V(f(an, bn))
end end
Vec.__add  = bin(function(a, b) return a + b end)
Vec.__sub  = bin(function(a, b) return a - b end)
Vec.__mul  = bin(function(a, b) return a * b end)
Vec.__div  = bin(function(a, b) return a / b end)
Vec.__mod  = bin(function(a, b) return a % b end)
Vec.__pow  = bin(function(a, b) return a ^ b end)
Vec.__idiv = bin(function(a, b) return a // b end)
Vec.__band = bin(function(a, b) return a & b end)
Vec.__bor  = bin(function(a, b) return a | b end)
Vec.__bxor = bin(function(a, b) return a ~ b end)
Vec.__shl  = bin(function(a, b) return a << b end)
Vec.__shr  = bin(function(a, b) return a >> b end)
Vec.__unm  = function(a) return V(-a.n) end
Vec.__bnot = function(a) return V(~a.n) end
Vec.__eq   = function(a, b) return a.n == b.n end
Vec.__lt   = function(a, b) return a.n < b.n end
Vec.__le   = function(a, b) return a.n <= b.n end
Vec.__concat = function(a, b)
  local an = type(a) == "table" and a.n or a
  local bn = type(b) == "table" and b.n or b
  return tostring(an) .. "|" .. tostring(bn)
end
Vec.__len  = function(a) return a.n end
Vec.__tostring = function(a) return "V(" .. a.n .. ")" end
Vec.__call = function(self, x) return self.n + x end

-- arithmetic metamethods
show((V(10) + V(3)).n, (V(10) - V(3)).n, (V(10) * V(3)).n)
show((V(10) / V(4)).n, (V(10) % V(3)).n, (V(2) ^ V(8)).n, (V(10) // V(3)).n)
-- with a plain number on either side (commutativity via the metamethod)
show((V(5) + 100).n, (100 + V(5)).n, (V(20) - 5).n, (100 - V(40)).n)

-- bitwise metamethods
show((V(0xF0) & V(0x3F)).n, (V(0xF0) | V(0x0F)).n, (V(0xFF) ~ V(0x0F)).n)
show((V(1) << V(4)).n, (V(256) >> V(2)).n, (-V(5)).n, (~V(0)).n)

-- comparison metamethods (__eq only fires for same primitive type)
show(V(5) == V(5), V(5) == V(6), V(3) < V(5), V(5) <= V(5), V(7) <= V(3))

-- __concat (both sides, mixing with strings/numbers)
show(V(1) .. V(2), V(7) .. "x", "y" .. V(9))

-- __len and __call
show(#V(42), V(10)(5))                               -- 42 15

-- __tostring drives print/tostring
show(tostring(V(99)))

-- __index chain: function fallback after table miss
do
  local base = {greet = "hi"}
  local mid  = setmetatable({mid = true}, {__index = base})
  local top  = setmetatable({top = 1}, {__index = mid})
  show(top.top, top.mid, top.greet, top.missing)     -- 1 true hi nil
end

-- __index as function returning computed values, plus rawget bypass
do
  local t = setmetatable({real = "R"}, {
    __index = function(_, k) return "computed_" .. k end,
  })
  show(t.real, t.anything, rawget(t, "real"), rawget(t, "anything"))
end

-- __newindex: function form logs, table form redirects, rawset bypasses
do
  local writes = {}
  local store = {}
  local t = setmetatable({}, {
    __newindex = function(_, k, v) writes[#writes+1] = k .. "=" .. tostring(v); store[k] = v end,
  })
  t.a = 1; t.b = 2
  rawset(t, "c", 3)                                   -- bypass: no log
  show(table.concat(writes, ","), store.a, store.b, rawget(t, "c"))
end
do
  local backing = {}
  local proxy = setmetatable({}, {__newindex = backing})
  proxy.x = 10                                        -- redirected to backing
  show(rawget(proxy, "x"), backing.x)                 -- nil 10
end

-- getmetatable / setmetatable and __metatable protection
do
  local locked = setmetatable({}, {__metatable = "locked!"})
  show(getmetatable(locked))                          -- locked!
  show(pcall(setmetatable, locked, {}))               -- false (protected)
end

-- __eq does NOT fire across different metatables in 5.4? It DOES if both are tables
-- with metamethods; here both share Vec, already covered. Check primitive eq path:
show(V(1) == 1)                                       -- false (different types, no mm)
