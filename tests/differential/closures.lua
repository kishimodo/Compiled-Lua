-- tests/differential/closures.lua : closures, upvalues, varargs, recursion, and
-- pcall must produce byte-identical stdout under the JIT and the -i interpreter.
-- The runner runs both and diffs stdout; any divergence is a JIT miscompile.
local function counter()
  local n = 0
  return function() n = n + 1; return n end
end
local c = counter()
print(c(), c(), c())

local function sum(...)
  local s, n = 0, select("#", ...)
  for i = 1, n do s = s + (select(i, ...)) end
  return s
end
print(sum(1, 2, 3, 4, 5))

local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(fib(15))

local ok, err = pcall(function() error("boom") end)
print(ok, err and (err:match("boom") ~= nil))
