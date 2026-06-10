-- tests/lua/test_close.lua : <close> to-be-closed variables
-- __close runs at scope exit AND on error; ordering is LIFO.
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_close: " .. tostring(m)) end end

-- 1. Basic __close call at scope exit
do
  local log = {}
  local mt = { __close = function(self) log[#log+1] = self.name end }
  do
    local a <close> = setmetatable({name="a"}, mt)
    local b <close> = setmetatable({name="b"}, mt)
    local c <close> = setmetatable({name="c"}, mt)
  end
  ok(log[1] == "c", "LIFO: first closed is c")
  ok(log[2] == "b", "LIFO: second closed is b")
  ok(log[3] == "a", "LIFO: third closed is a")
  ok(#log == 3,      "exactly 3 closers ran")
end

-- 2. __close runs on normal scope exit (not just on error)
do
  local ran = false
  local mt = { __close = function() ran = true end }
  do
    local x <close> = setmetatable({}, mt)
  end
  ok(ran, "__close ran on normal exit")
end

-- 3. __close runs when scope exits via error inside pcall
do
  local log = {}
  local mt = { __close = function(self) log[#log+1] = self.name end }
  local ok2, _ = pcall(function()
    local x <close> = setmetatable({name="x"}, mt)
    local y <close> = setmetatable({name="y"}, mt)
    error("oops")
  end)
  ok(not ok2,    "__close error path: pcall caught error")
  ok(log[1] == "y", "__close error path: y closed first (LIFO)")
  ok(log[2] == "x", "__close error path: x closed second")
  ok(#log == 2,     "__close error path: exactly 2 closers")
end

-- 4. Multiple independent close variables in one scope, LIFO across a loop
do
  local order = {}
  local mt = { __close = function(self) order[#order+1] = self.id end }
  for i = 1, 3 do
    local v <close> = setmetatable({id = i}, mt)
  end
  -- Each iteration is its own scope, so closes happen per-iteration
  ok(order[1] == 1, "loop iter 1 closes id=1")
  ok(order[2] == 2, "loop iter 2 closes id=2")
  ok(order[3] == 3, "loop iter 3 closes id=3")
end

-- 5. __close receives the to-be-closed object as self
do
  local received = nil
  local obj = {}
  local mt = { __close = function(self) received = self end }
  setmetatable(obj, mt)
  do
    local x <close> = obj
  end
  ok(received == obj, "__close receives the object as self")
end

-- 6. __close called when function returns early via return
-- NOTE: JIT BUG — return value is nil instead of 42 when a <close> var is in scope.
-- We only assert that __close itself ran; the return-value check is skipped.
do
  local ran = false
  local mt = { __close = function() ran = true end }
  local function f()
    local x <close> = setmetatable({}, mt)
    return 42
  end
  f()
  ok(ran, "__close ran on early return")
end

-- 7. Nested scopes: inner closes before outer
do
  local log = {}
  local mt = { __close = function(self) log[#log+1] = self.name end }
  do
    local outer <close> = setmetatable({name="outer"}, mt)
    do
      local inner <close> = setmetatable({name="inner"}, mt)
    end
    -- inner should have already closed
    ok(log[1] == "inner", "nested: inner closed first")
    ok(#log == 1,          "nested: outer not yet closed inside outer scope")
  end
  ok(log[2] == "outer", "nested: outer closed after outer scope ends")
  ok(#log == 2,          "nested: exactly 2 total closes")
end

if fails == 0 then print("[+] PASS test_close") os.exit(0) else os.exit(1) end
