-- metatable OOP: a Stack with methods (SELF calls + __index)
local Stack = {}
Stack.__index = Stack
function Stack.new() return setmetatable({ items = {}, n = 0 }, Stack) end
function Stack:push(v) self.n = self.n + 1; self.items[self.n] = v end
function Stack:pop() local v = self.items[self.n]; self.items[self.n] = nil; self.n = self.n - 1; return v end
function Stack:size() return self.n end

local s = Stack.new()
for i = 1, 5 do s:push(i * i) end
print("size", s:size())
local sum = 0
while s:size() > 0 do sum = sum + s:pop() end
print("sum", sum)

-- closure counter sharing an upvalue
local function counter()
  local c = 0
  return function() c = c + 1; return c end
end
local f = counter()
print("counter", f(), f(), f())

-- recursion
local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end
print("fib", fib(20))

-- generic-for over a built map, sorted-ish via numeric keys
local m = {}
for i = 1, 6 do m[i] = i * 10 end
local acc = 0
for k, v in ipairs(m) do acc = acc + k + v end
print("acc", acc)

-- varargs + string.format
local function fmt(...) return string.format("(%d,%d,%d)", ...) end
print(fmt(7, 8, 9))
