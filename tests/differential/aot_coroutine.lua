-- Fiber-based coroutines (Plan 4): create/resume/yield/wrap/status, plus a yield
-- across a nested native call frame. Compiled by aotc, byte-diffed vs luavm.exe -i.
local co = coroutine.create(function()
  coroutine.yield(1)
  coroutine.yield(2)
  return 3
end)
print(coroutine.status(co))
print(coroutine.resume(co))
print(coroutine.resume(co))
print(coroutine.resume(co))
print(coroutine.resume(co))
print(coroutine.status(co))

-- wrap + squares
local g = coroutine.wrap(function()
  for i = 1, 4 do coroutine.yield(i * i) end
end)
print(g(), g(), g(), g())

-- yield across a nested function call (the fiber-stack test)
local deep = coroutine.create(function()
  local function inner() coroutine.yield("deep") end
  inner()
  return "done"
end)
print(coroutine.resume(deep))
print(coroutine.resume(deep))

-- producer/consumer via the for-in iterator protocol
for item in coroutine.wrap(function()
  for i = 1, 3 do coroutine.yield("item" .. i) end
end) do
  print(item)
end
