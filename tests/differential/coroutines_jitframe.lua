-- Coroutine yield/resume/nesting/wrap under the JIT must match the interpreter.
-- coroutine.resume now saves/restores g_CurrentJitFrame around the fiber switch
-- (so each fiber owns its JIT recovery frame); this exercises the common paths
-- to prove that swap doesn't disturb normal coroutine control flow. Deterministic
-- prints; the runner diffs JIT stdout against -i.

-- wrap + yield sequence
local sq = coroutine.wrap(function() for i = 1, 5 do coroutine.yield(i * i) end end)
local acc = {}
for v in sq do acc[#acc + 1] = v end
print("wrap", table.concat(acc, ","))

-- value threading through resume/yield
local co = coroutine.create(function(a, b)
  local c = coroutine.yield(a + b)
  local d = coroutine.yield(c * 2)
  return a, b, c, d
end)
print("r1", coroutine.resume(co, 10, 20))
print("r2", coroutine.resume(co, 5))
print("r3", coroutine.resume(co, 99))
print("r4", coroutine.resume(co))   -- dead

-- nested coroutines: outer drives inner across multiple resumes
local inner = coroutine.create(function()
  coroutine.yield("a"); coroutine.yield("b"); return "done"
end)
local outer = coroutine.create(function()
  local _, x = coroutine.resume(inner); coroutine.yield("outer-" .. x)
  local _, y = coroutine.resume(inner); coroutine.yield("outer-" .. y)
  local _, z = coroutine.resume(inner); return "outer-" .. z
end)
print(coroutine.resume(outer))
print(coroutine.resume(outer))
print(coroutine.resume(outer))

-- error propagation through resume
local boom = coroutine.create(function() error("kaboom") end)
local eok, eerr = coroutine.resume(boom)
print("err", eok, tostring(eerr):match("kaboom") ~= nil)

-- a JIT-heavy coroutine body (loops/arithmetic) producing a Fibonacci stream
local fib = coroutine.wrap(function()
  local a, b = 0, 1
  while true do coroutine.yield(a); a, b = b, a + b end
end)
local fibs = {}
for i = 1, 12 do fibs[i] = fib() end
print("fib", table.concat(fibs, ","))
