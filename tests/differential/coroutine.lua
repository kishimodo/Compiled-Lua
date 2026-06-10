-- tests/differential/coroutine.lua : producer/consumer with coroutine.wrap; print the produced sequence
-- Both JIT and interpreter must produce byte-identical stdout.

-- 1. Producer/consumer with coroutine.wrap
local function producer(items)
  return coroutine.wrap(function()
    for _, v in ipairs(items) do
      coroutine.yield(v)
    end
  end)
end

local gen = producer({10, 20, 30, 40, 50})
local results = {}
for v in gen do
  results[#results+1] = v
end
for i, v in ipairs(results) do
  print(i, v)
end

-- 2. Producer with transformation
local function transformed_producer(n)
  return coroutine.wrap(function()
    for i = 1, n do
      coroutine.yield(i, i*i)   -- yield pairs
    end
  end)
end

print("---")
for i, sq in transformed_producer(5) do
  print(i, sq)
end

-- 3. Coroutine-based pipeline: filter then map
local function filter_gen(n, pred)
  return coroutine.wrap(function()
    for i = 1, n do
      if pred(i) then coroutine.yield(i) end
    end
  end)
end

local function map_gen(src, fn)
  return coroutine.wrap(function()
    for v in src do
      coroutine.yield(fn(v))
    end
  end)
end

print("---")
local evens = filter_gen(10, function(x) return x % 2 == 0 end)
local doubled = map_gen(evens, function(x) return x * 2 end)
for v in doubled do
  print(v)
end

-- 4. Passing values back via resume
local co = coroutine.create(function(start)
  local acc = start
  while true do
    local delta = coroutine.yield(acc)
    if delta == nil then break end
    acc = acc + delta
  end
  return acc
end)

print("---")
local _, v = coroutine.resume(co, 100)   -- start=100, first yield: 100
print(v)
_, v = coroutine.resume(co, 5)           -- delta=5, yield: 105
print(v)
_, v = coroutine.resume(co, 10)          -- delta=10, yield: 115
print(v)
_, v = coroutine.resume(co, 20)          -- delta=20, yield: 135
print(v)

-- 5. Coroutine status sequence
print("---")
local co2 = coroutine.create(function()
  coroutine.yield("first")
  coroutine.yield("second")
  return "done"
end)
print(coroutine.status(co2))        -- suspended
local _, a = coroutine.resume(co2)
print(a)                             -- first
print(coroutine.status(co2))        -- suspended
local _, b = coroutine.resume(co2)
print(b)                             -- second
local _, c = coroutine.resume(co2)
print(c)                             -- done
print(coroutine.status(co2))        -- dead

-- 6. Fibonacci generator
print("---")
local function fib_gen()
  return coroutine.wrap(function()
    local a, b = 0, 1
    for _ = 1, 10 do
      coroutine.yield(a)
      a, b = b, a + b
    end
  end)
end

local fibs = {}
for n in fib_gen() do
  fibs[#fibs+1] = n
end
print(table.concat(fibs, " "))

-- 7. Nested coroutines
print("---")
local inner_co = coroutine.create(function()
  coroutine.yield(1)
  coroutine.yield(2)
  coroutine.yield(3)
end)

local outer_co = coroutine.create(function()
  while true do
    local ok, v = coroutine.resume(inner_co)
    if not ok or v == nil then break end
    coroutine.yield(v * 10)
  end
end)

local vals = {}
while true do
  local ok, v = coroutine.resume(outer_co)
  if not ok or v == nil then break end
  vals[#vals+1] = v
end
print(table.concat(vals, " "))
