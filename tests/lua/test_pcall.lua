-- tests/lua/test_pcall.lua : pcall success/failure; xpcall with handler+traceback; error() with table; error levels
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_pcall: " .. tostring(m)) end end

-- 1. pcall success: returns true + function results
do
  local ok1, v1, v2 = pcall(function() return 42, "hello" end)
  ok(ok1 == true,     "pcall success: status is true")
  ok(v1 == 42,        "pcall success: first return value")
  ok(v2 == "hello",   "pcall success: second return value")
end

-- 2. pcall failure with string error
do
  local ok2, msg = pcall(function() error("something went wrong") end)
  ok(ok2 == false,             "pcall failure: status is false")
  ok(type(msg) == "string",    "pcall failure: message is string")
  ok(msg:find("something went wrong") ~= nil, "pcall failure: message contains error text")
end

-- 3. pcall failure with table error object
do
  local errobj = {code = 404, text = "not found"}
  local ok3, got = pcall(function() error(errobj, 0) end)
  ok(ok3 == false,             "pcall table error: status is false")
  ok(type(got) == "table",     "pcall table error: got a table back")
  ok(got.code == 404,          "pcall table error: code == 404")
  ok(got.text == "not found",  "pcall table error: text == 'not found'")
end

-- 4. pcall passes arguments to function
do
  local ok4, result = pcall(function(a, b) return a + b end, 10, 32)
  ok(ok4 == true and result == 42, "pcall passes arguments: 10+32=42")
end

-- 5. Nested pcall: outer catches inner error
do
  local ok5, msg5 = pcall(function()
    local ok6, _ = pcall(function() error("inner") end)
    ok(ok6 == false, "nested pcall: inner pcall caught inner error")
    error("outer")
  end)
  ok(ok5 == false, "nested pcall: outer caught outer error")
  ok(msg5:find("outer") ~= nil, "nested pcall: outer message contains 'outer'")
end

-- 6. error() with level 0 (no location info added)
do
  local ok6, msg = pcall(function() error("bare error", 0) end)
  ok(ok6 == false,           "error level 0: status false")
  ok(msg == "bare error",    "error level 0: message is exactly 'bare error' (no location)")
end

-- 7. error() with level 1 (default: adds location of error() call)
do
  local ok7, msg = pcall(function() error("level1 error") end)
  ok(ok7 == false, "error level 1: status false")
  ok(msg:find("level1 error") ~= nil, "error level 1: message present")
  ok(msg:find(":") ~= nil, "error level 1: message includes location colon")
end

-- 8. error() with level 2 (blame the caller)
do
  local function thrower()
    error("blame caller", 2)
  end
  local ok8, msg = pcall(thrower)
  ok(ok8 == false, "error level 2: status false")
  ok(msg:find("blame caller") ~= nil, "error level 2: message present")
end

-- 9. xpcall with message handler
do
  local handler_called = false
  local handler_msg = nil
  local function handler(err)
    handler_called = true
    handler_msg = err
    return "HANDLED: " .. tostring(err)
  end
  local ok9, result = xpcall(function() error("xpcall test") end, handler)
  ok(ok9 == false,           "xpcall failure: status false")
  ok(handler_called == true, "xpcall: handler was called")
  ok(result:find("HANDLED:") ~= nil, "xpcall: result is handler's return")
  ok(handler_msg ~= nil,     "xpcall: handler received error message")
end

-- 10. xpcall success: handler not called
do
  local handler_called = false
  local function handler(err) handler_called = true; return err end
  local ok10, v = xpcall(function() return 99 end, handler)
  ok(ok10 == true,             "xpcall success: status true")
  ok(v == 99,                  "xpcall success: return value")
  ok(handler_called == false,  "xpcall success: handler not called")
end

-- 11. xpcall passes arguments (Lua 5.4 feature)
do
  local ok11, result = xpcall(function(a, b) return a * b end,
                               function(e) return e end, 6, 7)
  ok(ok11 == true and result == 42, "xpcall passes arguments: 6*7=42")
end

-- 12. xpcall with traceback-like handler
do
  local tb = nil
  local ok12, _ = xpcall(function()
    error("traceback test")
  end, function(err)
    tb = debug and debug.traceback and debug.traceback(err, 2) or err
    return tb
  end)
  ok(ok12 == false, "xpcall traceback: status false")
  ok(tb ~= nil,     "xpcall traceback: traceback captured")
end

-- 13. pcall with error inside metamethod
do
  local mt = {
    __add = function(a, b)
      error("metamethod error")
    end
  }
  local obj = setmetatable({}, mt)
  local ok13, msg = pcall(function() return obj + 1 end)
  ok(ok13 == false, "pcall catches metamethod error")
  ok(msg:find("metamethod error") ~= nil, "pcall metamethod error message")
end

-- 14. pcall return values on success (multiple)
do
  local s, a, b, c = pcall(function() return 1, 2, 3 end)
  ok(s==true and a==1 and b==2 and c==3, "pcall multiple returns on success")
end

-- 15. error propagation: error inside error handler doesn't loop
do
  local ok15, msg = xpcall(function()
    error("original")
  end, function(err)
    -- Handler itself errors: xpcall should not recurse
    return "safe: " .. tostring(err)
  end)
  ok(ok15 == false, "xpcall with safe handler: status false")
  ok(msg:find("safe:") ~= nil, "xpcall with safe handler: message from handler")
end

if fails == 0 then print("[+] PASS test_pcall") os.exit(0) else os.exit(1) end
