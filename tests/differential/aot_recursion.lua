-- AOT differential: recursion + tail calls (Plan 3 + C3 ProtoInit roots-only
-- fix — nested user-function Protos must be built exactly once). Direct
-- recursion (fact/fib), mutual recursion, and a tail-recursive accumulator.

-- direct recursion
local function fact(n)
  if n <= 1 then return 1 else return n * fact(n - 1) end
end
print(fact(0), fact(1), fact(5), fact(10))

-- fibonacci (double recursion)
local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end
print(fib(0), fib(1), fib(10), fib(15), fib(20))

-- mutual recursion
local isodd, iseven
function isodd(n) if n == 0 then return false else return iseven(n - 1) end end
function iseven(n) if n == 0 then return true else return isodd(n - 1) end end
print(isodd(7), iseven(10), isodd(0), iseven(1))

-- tail-recursive accumulator (exercises OP_TAILCALL)
local function sum_to(n, acc)
  acc = acc or 0
  if n == 0 then return acc end
  return sum_to(n - 1, acc + n)
end
print(sum_to(10), sum_to(100), sum_to(1000))

-- a tail call to another function returning multiple results
local function two() return 1, 2 end
local function forward() return two() end
print(forward())
