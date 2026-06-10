-- AOT differential: user-defined functions, closures, upvalue capture+mutation,
-- higher-order functions, nested closures sharing an upvalue (Plan 3
-- CLOSURE/GETUPVAL/SETUPVAL). Exercises the C2 RETURN-with-close fix: a function
-- that returns a closure over its locals must Rt_Close before returning.

-- plain function def + call
local function add(a, b) return a + b end
print(add(3, 4), add(10, 20), add(-5, 5))

-- higher-order: a function value passed and called
local function apply(g, x) return g(x) end
print(apply(function(y) return y * y end, 7))

-- counter closure: an upvalue mutated across calls (the function returning the
-- inner closure exercises RETURN-with-k-flag / Rt_Close)
local function mk_counter()
  local c = 0
  return function() c = c + 1 return c end
end
local f = mk_counter()
print(f(), f(), f())

-- two counters must have INDEPENDENT upvalues
local g = mk_counter()
print(f(), g(), f(), g())

-- accumulator closure with an init upvalue
local function make_acc(init)
  local total = init
  return function(x) total = total + x return total end
end
local a = make_acc(100)
local b = make_acc(0)
print(a(5), a(5), b(1), b(1), a(0))

-- nested closures sharing ONE upvalue (inc mutates, get reads)
local function make_pair()
  local x = 0
  local function inc() x = x + 1 end
  local function get() return x end
  return inc, get
end
local i, gg = make_pair()
i() i() i()
print(gg())
