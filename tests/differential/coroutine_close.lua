-- coroutine.close must run the coroutine's pending to-be-closed variables.
--
-- CLua's coroutine library is fiber-based (clua/src/runtime/coro.c) rather than
-- upstream's, so every part of it is a reimplementation that can drift from the
-- reference. Three things were wrong here and none of them was caught, because
-- 47% of the suite is CLua-vs-CLua stdout diffs and a defect shared by both
-- engines passes silently. All three were confirmed against a real Lua 5.4 built
-- from lua-5.4/src:
--
--   1. `<close>` handlers were NEVER run by coroutine.close. Every to-be-closed
--      variable in an abandoned coroutine was skipped, so file handles, locks and
--      FFI allocations leaked -- while the call still returned true.
--   2. A `__close` that errors returned (true, nil) instead of (false, err), so a
--      caller checking the result saw success.
--   3. Closing a RUNNING coroutine returned nil+message instead of raising, so
--      pcall reported success and handed back a nil the caller had no reason to
--      check.
--
-- tests/conformance/coroutines.lua:115 already carried the correct expected value
-- in a comment while passing with the wrong one.

local function tag(...) return table.concat({ ... }, "\t") end

-- 1. A pending <close> runs, and close reports success.
do
  local closed = false
  local co = coroutine.create(function()
    local guard <close> = setmetatable({}, { __close = function() closed = true end })
    coroutine.yield("suspended")
    return "unreached"
  end)
  local _, y = coroutine.resume(co)
  local ok, err = coroutine.close(co)
  print(tag("pending", y, tostring(ok), tostring(err), "closed=" .. tostring(closed),
            coroutine.status(co)))
end

-- 2. Several <close> variables run in reverse declaration order.
do
  local order = {}
  local co = coroutine.create(function()
    local a <close> = setmetatable({}, { __close = function() order[#order+1] = "a" end })
    local b <close> = setmetatable({}, { __close = function() order[#order+1] = "b" end })
    local c <close> = setmetatable({}, { __close = function() order[#order+1] = "c" end })
    coroutine.yield()
  end)
  coroutine.resume(co)
  coroutine.close(co)
  print(tag("order", table.concat(order, ",")))
end

-- 3. An erroring __close surfaces as (false, err).
do
  local co = coroutine.create(function()
    local g <close> = setmetatable({}, { __close = function() error("boom") end })
    coroutine.yield()
  end)
  coroutine.resume(co)
  local ok, err = coroutine.close(co)
  print(tag("erroring", tostring(ok), (tostring(err):gsub("^.*:%d+: ", ""))))
end

-- 4. Closing a running coroutine RAISES.
do
  local co
  co = coroutine.create(function()
    local ok, err = pcall(coroutine.close, co)
    print(tag("self", tostring(ok), (tostring(err):gsub("^.*:%d+: ", ""))))
  end)
  coroutine.resume(co)
end

-- 5. Closing an already-dead coroutine is a no-op that succeeds, and closing
--    twice must not run the handler twice.
do
  local n = 0
  local co = coroutine.create(function()
    local g <close> = setmetatable({}, { __close = function() n = n + 1 end })
    coroutine.yield()
  end)
  coroutine.resume(co)
  local ok1 = coroutine.close(co)
  local ok2 = coroutine.close(co)
  print(tag("twice", tostring(ok1), tostring(ok2), "ran=" .. tostring(n)))
end

-- 6. A coroutine that finished normally has already closed its variables, so
--    close afterwards is a successful no-op.
do
  local closed = false
  local co = coroutine.create(function()
    local g <close> = setmetatable({}, { __close = function() closed = true end })
    return "finished"
  end)
  local _, r = coroutine.resume(co)
  local before = closed
  local ok = coroutine.close(co)
  print(tag("normal-exit", r, "closed-on-return=" .. tostring(before), tostring(ok)))
end

print("DONE")
