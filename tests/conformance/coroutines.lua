-- coroutines.lua : create/wrap/yield/resume/status/running/isyieldable/close,
-- errors propagated through resume, nested coroutines, yield across pcall.
-- Deterministic; JIT and -i must agree byte-for-byte.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- resume return convention: ok flag + yielded/returned values
do
  local co = coroutine.create(function(a, b)
    local c = coroutine.yield(a + b)        -- first yield
    local d = coroutine.yield(c * 2)        -- second yield
    return a, b, c, d                       -- final return
  end)
  show(coroutine.resume(co, 3, 4))          -- true 7
  show(coroutine.resume(co, 10))            -- true 20
  show(coroutine.resume(co, 99))            -- true 3 4 10 99
  show(coroutine.resume(co))                -- false cannot resume dead
  show(coroutine.status(co))                -- dead
end

-- status transitions and coroutine.running inside
do
  local seen = {}
  local co = coroutine.create(function()
    seen[#seen+1] = coroutine.status(coroutine.running())  -- running
    coroutine.yield()
  end)
  show(coroutine.status(co))                -- suspended
  coroutine.resume(co)
  show(coroutine.status(co))                -- suspended (after yield)
  show(seen[1])
end

-- isyieldable: false at top level, true inside a coroutine
show(coroutine.isyieldable())               -- false (main)
do
  local co = coroutine.wrap(function()
    coroutine.yield(coroutine.isyieldable())
  end)
  show(co())                                 -- true
end

-- wrap: errors are re-raised; capture via pcall
do
  local g = coroutine.wrap(function()
    coroutine.yield(1)
    error("boom")
  end)
  show(g())                                  -- 1
  show(pcall(g))                             -- false ...boom
end

-- create + error: resume returns false + message (not raised)
do
  local co = coroutine.create(function() error("inner failure") end)
  local ok, msg = coroutine.resume(co)
  show(ok, (msg:gsub("^.-:%d+: ", "")))      -- false inner failure (strip file:line)
  show(coroutine.status(co))                 -- dead
end

-- yielding multiple values and resuming with multiple values
do
  local co = coroutine.create(function()
    local x, y = coroutine.yield("a", "b", "c")
    return x + y
  end)
  show(coroutine.resume(co))                 -- true a b c
  show(coroutine.resume(co, 5, 6))           -- true 11
end

-- nested coroutines: outer resumes inner
do
  local inner = coroutine.create(function()
    for i = 1, 3 do coroutine.yield(i) end
  end)
  local outer = coroutine.wrap(function()
    while true do
      local ok, v = coroutine.resume(inner)
      if not ok or v == nil then return end
      coroutine.yield(v * 100)
    end
  end)
  local out = {}
  for v in outer do out[#out+1] = v end
  show(table.concat(out, ","))               -- 100,200,300
end

-- yield across a pcall boundary (Lua 5.4 supports this)
do
  local co = coroutine.wrap(function()
    local ok, v = pcall(function()
      return coroutine.yield("through-pcall")
    end)
    coroutine.yield(ok, v)
  end)
  show(co())                                  -- through-pcall
  show(co("resumed"))                         -- true resumed
end

-- coroutine.close: close a suspended coroutine, status becomes dead
do
  local closed = false
  local co = coroutine.create(function()
    local guard <close> = setmetatable({}, {__close = function() closed = true end})
    coroutine.yield(1)
    coroutine.yield(2)
  end)
  coroutine.resume(co)                        -- runs to first yield
  show(coroutine.status(co))                  -- suspended
  local ok = coroutine.close(co)
  show(ok, coroutine.status(co), closed)      -- true dead true
end
