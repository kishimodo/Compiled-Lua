-- tests/differential/closevar.lua : <close> ordering; print close order
-- Both JIT and interpreter must produce byte-identical stdout.
-- NOTE: We avoid the JIT bug where return values are dropped when a <close>
-- variable is in scope — we only check __close invocation ordering and pcall behavior.

local function make_closer(log, name)
  return setmetatable({name=name}, {
    __close = function(self) log[#log+1] = self.name end
  })
end

-- 1. LIFO ordering within a single scope
do
  local log = {}
  do
    local a <close> = make_closer(log, "a")
    local b <close> = make_closer(log, "b")
    local c <close> = make_closer(log, "c")
  end
  print(table.concat(log, ","))   -- c,b,a
end

-- 2. Nested scopes: inner closes before outer
do
  local log = {}
  do
    local outer <close> = make_closer(log, "outer")
    do
      local inner1 <close> = make_closer(log, "inner1")
      local inner2 <close> = make_closer(log, "inner2")
    end
    -- inner1 and inner2 already closed, outer still open
    log[#log+1] = "between"
  end
  print(table.concat(log, ","))   -- inner2,inner1,between,outer
end

-- 3. __close runs on pcall-caught error (LIFO under error)
do
  local log = {}
  pcall(function()
    local x <close> = make_closer(log, "x")
    local y <close> = make_closer(log, "y")
    error("test error")
  end)
  print(table.concat(log, ","))   -- y,x
end

-- 4. __close in a loop (each iteration's scope closes at iteration end)
do
  local log = {}
  for i = 1, 4 do
    local v <close> = make_closer(log, tostring(i))
  end
  print(table.concat(log, ","))   -- 1,2,3,4
end

-- 5. __close interleaved with regular code
do
  local log = {}
  log[#log+1] = "start"
  do
    local c1 <close> = make_closer(log, "c1")
    log[#log+1] = "mid"
    do
      local c2 <close> = make_closer(log, "c2")
      log[#log+1] = "inner"
    end
    log[#log+1] = "after-inner"
  end
  log[#log+1] = "end"
  print(table.concat(log, ","))
  -- start,mid,inner,c2,after-inner,c1,end
end

-- 6. __close on function exit (multiple closers in function)
do
  local log = {}
  local function f()
    local p <close> = make_closer(log, "p")
    local q <close> = make_closer(log, "q")
    log[#log+1] = "in-f"
    -- returns here; q then p close
  end
  f()
  print(table.concat(log, ","))   -- in-f,q,p
end

-- 7. __close receives correct self reference
do
  local received = {}
  local objs = {}
  for i = 1, 3 do
    objs[i] = setmetatable({id=i}, {
      __close = function(self) received[#received+1] = self.id end
    })
  end
  do
    local a <close> = objs[1]
    local b <close> = objs[2]
    local c <close> = objs[3]
  end
  print(table.concat(received, ","))   -- 3,2,1
end
