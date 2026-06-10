-- tests/lua/test_coroutines.lua : coroutine create/resume/yield/status/isyieldable/running; wrap; error propagation
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_coroutines: " .. tostring(m)) end end

-- 1. Basic create/resume/yield
do
  local co = coroutine.create(function(a, b)
    coroutine.yield(a + b)
    coroutine.yield(a * b)
    return a - b
  end)
  ok(coroutine.status(co) == "suspended", "new coroutine is suspended")
  local ok1, v1 = coroutine.resume(co, 3, 4)
  ok(ok1 == true and v1 == 7,  "first resume: ok=true, yield 3+4=7")
  ok(coroutine.status(co) == "suspended", "after first yield: still suspended")
  local ok2, v2 = coroutine.resume(co)
  ok(ok2 == true and v2 == 12, "second resume: ok=true, yield 3*4=12")
  local ok3, v3 = coroutine.resume(co)
  ok(ok3 == true and v3 == -1, "third resume: ok=true, return 3-4=-1")
  ok(coroutine.status(co) == "dead", "after return: coroutine is dead")
  local ok4, v4 = coroutine.resume(co)
  ok(ok4 == false, "resume dead coroutine returns false")
  ok(type(v4) == "string", "resume dead coroutine gives error message")
end

-- 2. coroutine.status values
do
  local inner_status = nil
  local co = coroutine.create(function()
    inner_status = coroutine.status(coroutine.running())
    coroutine.yield()
  end)
  local ok1, _ = coroutine.resume(co)
  ok(ok1, "resume running status test")
  ok(inner_status == "running", "status inside running coroutine is 'running'")
  ok(coroutine.status(co) == "suspended", "status after yield is 'suspended'")
  coroutine.resume(co)
  ok(coroutine.status(co) == "dead", "status after finish is 'dead'")
end

-- 3. coroutine.isyieldable and coroutine.running
do
  ok(coroutine.isyieldable() == false, "main thread is not yieldable")
  ok(coroutine.running() == nil or type(coroutine.running()) == "thread",
     "coroutine.running() in main: nil or thread")
  local from_inside = false
  local running_ref = nil
  local co = coroutine.create(function()
    from_inside = coroutine.isyieldable()
    running_ref = coroutine.running()
    coroutine.yield()
  end)
  coroutine.resume(co)
  ok(from_inside == true,    "isyieldable inside coroutine is true")
  ok(running_ref == co,      "coroutine.running() inside returns self")
end

-- 4. Passing values through yield/resume
do
  local co = coroutine.create(function(init)
    local x = coroutine.yield(init * 2)  -- yield init*2, receive x on next resume
    local y = coroutine.yield(x * 3)     -- yield x*3, receive y
    return y + 1
  end)
  local _, v1 = coroutine.resume(co, 5)   -- init=5, yields 10
  ok(v1 == 10, "yield passes value to resumer: 5*2=10")
  local _, v2 = coroutine.resume(co, 7)   -- x=7, yields 21
  ok(v2 == 21, "yield receives value from resume: 7*3=21")
  local _, v3 = coroutine.resume(co, 4)   -- y=4, returns 5
  ok(v3 == 5,  "coroutine return value: 4+1=5")
end

-- 5. coroutine.wrap
do
  local function gen(max)
    return coroutine.wrap(function()
      for i = 1, max do
        coroutine.yield(i * i)
      end
    end)
  end
  local g = gen(5)
  local results = {}
  for i = 1, 5 do results[i] = g() end
  ok(results[1] == 1,  "wrap gen[1] == 1")
  ok(results[2] == 4,  "wrap gen[2] == 4")
  ok(results[3] == 9,  "wrap gen[3] == 9")
  ok(results[4] == 16, "wrap gen[4] == 16")
  ok(results[5] == 25, "wrap gen[5] == 25")
  -- 6th call: function body runs to completion and returns (wrap returns nothing)
  g()
  -- 7th call: coroutine is now dead, wrap raises error
  local ok5, _ = pcall(g)
  ok(ok5 == false, "calling dead wrap raises error")
end

-- 6. Error propagation out of a coroutine
do
  local co = coroutine.create(function()
    error("coroutine error")
  end)
  local ok6, msg = coroutine.resume(co)
  ok(ok6 == false, "error in coroutine: resume returns false")
  ok(type(msg) == "string", "error in coroutine: message is string")
  ok(msg:find("coroutine error") ~= nil, "error message contains 'coroutine error'")
  ok(coroutine.status(co) == "dead", "errored coroutine is dead")
end

-- 7. Error with non-string value
do
  local co = coroutine.create(function()
    error({code=42})
  end)
  local ok7, msg = coroutine.resume(co)
  ok(ok7 == false, "error with table: resume returns false")
  ok(type(msg) == "table" or type(msg) == "string",
     "error with table: msg is table or string (level-wrapped)")
end

-- 8. Coroutine yielding multiple values
do
  local co = coroutine.create(function()
    coroutine.yield(1, 2, 3)
    coroutine.yield()
    return 10, 20
  end)
  local ok8, a, b, c = coroutine.resume(co)
  ok(ok8 and a == 1 and b == 2 and c == 3, "yield multiple values: 1,2,3")
  local ok9, x = coroutine.resume(co)
  ok(ok9 and x == nil, "yield with no value: nil")
  local ok10, p, q = coroutine.resume(co)
  ok(ok10 and p == 10 and q == 20, "return multiple: 10,20")
end

-- 9. Nested coroutines
do
  local log = {}
  local inner = coroutine.create(function()
    log[#log+1] = "inner1"
    coroutine.yield()
    log[#log+1] = "inner2"
  end)
  local outer = coroutine.create(function()
    log[#log+1] = "outer1"
    coroutine.resume(inner)
    log[#log+1] = "outer2"
    coroutine.resume(inner)
    log[#log+1] = "outer3"
  end)
  coroutine.resume(outer)
  ok(log[1] == "outer1", "nested: outer1 first")
  ok(log[2] == "inner1", "nested: inner1 second")
  ok(log[3] == "outer2", "nested: outer2 third")
  ok(log[4] == "inner2", "nested: inner2 fourth")
  ok(log[5] == "outer3", "nested: outer3 fifth")
end

if fails == 0 then print("[+] PASS test_coroutines") os.exit(0) else os.exit(1) end
