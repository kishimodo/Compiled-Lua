-- close_tbc.lua : to-be-closed variables (<close>) -- LIFO ordering, close on
-- normal exit / break / goto / error, __close receiving the error, nested scopes.
-- Deterministic; JIT and -i must agree byte-for-byte.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end
local function closer(log, name)
  return setmetatable({}, {__close = function() log[#log+1] = name end})
end

-- LIFO close order at block exit
do
  local log = {}
  do
    local a <close> = closer(log, "a")
    local b <close> = closer(log, "b")
    local c <close> = closer(log, "c")
  end
  show(table.concat(log, ","))                 -- c,b,a
end

-- nested scopes: inner closes before outer continues
do
  local log = {}
  do
    local outer <close> = closer(log, "outer")
    do
      local i1 <close> = closer(log, "i1")
      local i2 <close> = closer(log, "i2")
    end
    log[#log+1] = "between"
  end
  show(table.concat(log, ","))                 -- i2,i1,between,outer
end

-- close on break out of a loop
do
  local log = {}
  for i = 1, 5 do
    local v <close> = closer(log, "v" .. i)
    if i == 3 then break end
  end
  show(table.concat(log, ","))                 -- v1,v2,v3
end

-- close on goto jumping out of a scope
do
  local log = {}
  do
    local g <close> = closer(log, "g")
    goto done
  end
  ::done::
  show(table.concat(log, ","))                 -- g
end

-- close on error caught by pcall (LIFO under error)
do
  local log = {}
  pcall(function()
    local x <close> = closer(log, "x")
    local y <close> = closer(log, "y")
    error("fail")
  end)
  show(table.concat(log, ","))                 -- y,x
end

-- __close receives the error object as its 2nd argument
do
  local seen
  pcall(function()
    local guard <close> = setmetatable({}, {
      __close = function(_, err) seen = err end,
    })
    error("the-error")
  end)
  show((tostring(seen):gsub("^.-:%d+: ", "")))  -- the-error
end

-- __close runs with nil error on normal exit.
-- NOTE: the side effect of __close on an upvalue read immediately afterward via a
-- function-call argument is exercised separately in close_upvalue_stale.lua (a
-- known JIT register-caching divergence). Here we observe the close via a plain
-- print so this file stays a clean PASS.
do
  local got = "unset"
  do
    local guard <close> = setmetatable({}, {
      __close = function(_, err) got = (err == nil) and "nil-err" or tostring(err) end,
    })
  end
  print("normal-exit-close:", got)              -- nil-err
end

-- a false / nil tbc value is allowed and simply skipped (no __close required)
do
  local log = {}
  do
    local a <close> = closer(log, "a")
    local skip <close> = nil                     -- allowed: no close called
    local b <close> = closer(log, "b")
  end
  show(table.concat(log, ","))                   -- b,a
end

-- close ordering across a loop body each iteration
do
  local log = {}
  for i = 1, 3 do
    local p <close> = closer(log, "p" .. i)
    local q <close> = closer(log, "q" .. i)
  end
  show(table.concat(log, ","))                   -- q1,p1,q2,p2,q3,p3
end

-- error inside one __close still runs the others (we just check both ran)
do
  local log = {}
  pcall(function()
    local a <close> = closer(log, "a")
    local b <close> = setmetatable({}, {__close = function() log[#log+1] = "b"; error("in-close") end})
    local c <close> = closer(log, "c")
  end)
  show(table.concat(log, ","))                   -- c,b,a
end
