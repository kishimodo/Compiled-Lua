-- closures_upvalues.lua : upvalue sharing, capture-by-reference, per-iteration
-- fresh upvalues, recursive closures, counters. Deterministic; JIT and -i agree.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- two closures SHARE the same upvalue (mutation visible to both)
do
  local function make_pair()
    local n = 0
    local function inc() n = n + 1; return n end
    local function get() return n end
    return inc, get
  end
  local inc, get = make_pair()
  inc(); inc(); inc()
  show(get())                                  -- 3
  inc()
  show(get())                                  -- 4
end

-- each loop iteration captures a FRESH variable (Lua 5.4: locals scoped per-iter)
do
  local fns = {}
  for i = 1, 3 do
    fns[i] = function() return i end
  end
  show(fns[1](), fns[2](), fns[3]())           -- 1 2 3
end

-- closing over a loop variable declared inside the body
do
  local fns = {}
  for i = 1, 3 do
    local captured = i * 10
    fns[i] = function() return captured end
  end
  show(fns[1](), fns[2](), fns[3]())           -- 10 20 30
end

-- counter factory: independent state per closure
do
  local function counter()
    local c = 0
    return function() c = c + 1; return c end
  end
  local a, b = counter(), counter()
  show(a(), a(), b(), a(), b())                -- 1 2 1 3 2
end

-- recursive closure via a forward-declared local
do
  local fact
  fact = function(n) if n <= 1 then return 1 else return n * fact(n - 1) end end
  show(fact(5), fact(6))                        -- 120 720
end

-- mutually recursive local functions sharing scope
do
  local is_even, is_odd
  is_even = function(n) if n == 0 then return true else return is_odd(n - 1) end end
  is_odd  = function(n) if n == 0 then return false else return is_even(n - 1) end end
  show(is_even(10), is_odd(7), is_even(3))      -- true true false
end

-- upvalue captured then the enclosing scope's local reused (still distinct)
do
  local getters = {}
  do
    local x = "first"
    getters[1] = function() return x end
  end
  do
    local x = "second"
    getters[2] = function() return x end
  end
  show(getters[1](), getters[2]())             -- first second
end

-- nested closures: three levels of upvalue capture
do
  local function outer(a)
    return function(b)
      return function(c)
        return a + b + c
      end
    end
  end
  show(outer(100)(20)(3))                       -- 123
end

-- shared upvalue mutated through one closure, read through another, in a table
do
  local obj = {}
  do
    local total = 0
    function obj.add(x) total = total + x end
    function obj.total() return total end
  end
  obj.add(5); obj.add(10); obj.add(100)
  show(obj.total())                             -- 115
end

-- accumulating closures in a list, each adds to a shared sum
do
  local sum = 0
  local adders = {}
  for i = 1, 5 do adders[i] = function() sum = sum + i end end
  for _, f in ipairs(adders) do f() end
  show(sum)                                      -- 15
end

-- closure capturing a <const> variable
do
  local PI <const> = 3.14
  local function area(r) return PI * r * r end
  show(area(2), area(10))                        -- 12.56 314.0
end
