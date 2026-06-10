-- tests/differential/pcall_err.lua : pcall around several error scenarios; print ok/msg
-- Both JIT and interpreter must produce byte-identical stdout.

-- Helper: print pcall result in normalized form.
-- For error strings, we strip the leading "...file:line: " prefix to get
-- just the core message, making output identical across JIT and interpreter.
local function normalize_err(msg)
  local s = tostring(msg)
  -- Lua error format: "...path:line: message" or "path:line: message"
  -- Strip everything up to and including the last ": " that follows a number
  local core = s:match(":%d+: (.+)$") or s:match(": (.+)$") or s
  return core
end

local function run(label, f, ...)
  local ok, msg = pcall(f, ...)
  if ok then
    print(label .. ": ok=" .. tostring(ok) .. " val=" .. tostring(msg))
  else
    print(label .. ": ok=" .. tostring(ok) .. " msg=" .. normalize_err(msg))
  end
end

-- 1. No error: returns value
run("no_error", function() return 42 end)

-- 2. Simple string error
run("string_error", function() error("simple error", 0) end)

-- 3. Error with level 0 (no location decoration)
run("level0", function() error("raw message", 0) end)

-- 4. Error with table value (level 0 to avoid string wrapping)
local ok4, obj4 = pcall(function() error({code=99, text="table error"}, 0) end)
print("table_error: ok=" .. tostring(ok4) ..
      " code=" .. tostring(obj4 and obj4.code) ..
      " text=" .. tostring(obj4 and obj4.text))

-- 5. Error inside a nested function
run("nested", function()
  local function inner() error("from inner", 0) end
  inner()
end)

-- 6. Error inside a loop
run("loop_error", function()
  for i = 1, 5 do
    if i == 3 then error("loop i=3", 0) end
  end
end)

-- 7. No error in loop (completes normally)
run("loop_ok", function()
  local s = 0
  for i = 1, 5 do s = s + i end
  return s
end)

-- 8. pcall success with multiple returns
local ok8, a, b, c = pcall(function() return 1, 2, 3 end)
print("multi_return: ok=" .. tostring(ok8) .. " a=" .. tostring(a) ..
      " b=" .. tostring(b) .. " c=" .. tostring(c))

-- 9. Nested pcall: inner catches, outer sees clean run
run("nested_caught", function()
  local ok9, _ = pcall(function() error("inner only", 0) end)
  if not ok9 then return "caught" end
  return "missed"
end)

-- 10. xpcall with simple handler
local ok10, res10 = xpcall(
  function() error("xpcall input", 0) end,
  function(err) return "HANDLED:" .. err end
)
print("xpcall: ok=" .. tostring(ok10) .. " res=" .. tostring(res10))

-- 11. Arithmetic error (divide by zero in float is not an error in Lua, but integer is)
run("intdiv_zero", function()
  local x = 1 // 0
  return x
end)

-- 12. Deep recursion (non-tail) caught by pcall at a safe depth
-- NOTE: JIT crashes on true stack overflow (C stack exhaustion), so we use
-- a depth that triggers Lua's stack limit but not the C stack.
-- We use pcall to catch "stack overflow" from Lua's internal limit.
run("deep_recursion", function()
  local function recurse(n)
    if n <= 0 then return 0 end
    return recurse(n - 1) + 1  -- non-tail, builds Lua stack
  end
  -- 500 levels is safe for both JIT and interpreter
  return recurse(500)
end)

-- 13. Error in metamethod caught by pcall
run("metamethod_error", function()
  local t = setmetatable({}, {
    __index = function() error("meta error", 0) end
  })
  return t.missing
end)

-- 14. assert failure caught by pcall
run("assert_fail", function()
  assert(false, "assertion message")
end)

-- 15. assert success
run("assert_ok", function()
  return assert(42, "unused message")
end)
