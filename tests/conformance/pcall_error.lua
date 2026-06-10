-- pcall_error.lua : pcall/xpcall/error with string AND table values, error levels,
-- message handlers, error object identity. Deterministic; JIT and -i must agree.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end
local function strip(msg) return (tostring(msg):gsub("^.-:%d+: ", "")) end

-- pcall: success returns true + results
show(pcall(function() return 1, 2, 3 end))           -- true 1 2 3
show(pcall(function(a, b) return a + b end, 10, 20))  -- true 30

-- pcall: failure returns false + message
show(pcall(function() error("simple") end))           -- false ...simple
do
  local ok, msg = pcall(function() error("plain") end)
  show(ok, strip(msg))                                -- false plain
end

-- error with a NON-string value (table) passes the object through unchanged
do
  local errobj = {code = 42, msg = "structured"}
  local ok, e = pcall(function() error(errobj) end)
  show(ok, type(e), e == errobj, e.code, e.msg)       -- false table true 42 structured
end

-- error level 0 suppresses position info
do
  local ok, msg = pcall(function() error("no-position", 0) end)
  show(ok, msg)                                       -- false no-position
end

-- error level 2 blames the caller (we only check it's a string with a colon)
do
  local function lib() error("level2", 2) end
  local ok, msg = pcall(function() lib() end)
  show(ok, type(msg), (msg:find(": level2$") ~= nil)) -- false string true
end

-- error with nil and with a number
show(pcall(function() error() end))                   -- false nil
show(pcall(function() error(404) end))                -- false 404 (number passes through)

-- runtime errors (not via error()) are caught too
show(pcall(function() return nil + 1 end))            -- false ...arithmetic
show(pcall(function() local t = nil; return t.x end)) -- false ...index nil
show(pcall(function() return (nil)() end))            -- false ...call nil

-- nested pcall: inner catches, outer sees success
do
  local ok, inner_ok, inner_msg = pcall(function()
    return pcall(function() error("deep") end)
  end)
  show(ok, inner_ok, strip(inner_msg))                -- true false deep
end

-- xpcall with a message handler that transforms the error
do
  local function handler(err) return "HANDLED:" .. strip(err) end
  show(xpcall(function() error("xp") end, handler))   -- false HANDLED:xp
end

-- xpcall passes extra args to the protected function (Lua 5.2+)
do
  local function handler(e) return e end
  show(xpcall(function(a, b) return a * b end, handler, 6, 7))  -- true 42
end

-- xpcall handler can inspect a table error object
do
  local function handler(e)
    if type(e) == "table" then return "obj:" .. e.id end
    return "str:" .. tostring(e)
  end
  show(xpcall(function() error({id = "X1"}) end, handler))
end

-- assert: passes value through on truthy, errors with message on falsy
show(pcall(function() return assert(5, "unused") end))      -- true 5
show(pcall(function() assert(false, "assert-msg") end))      -- false assert-msg
show(pcall(function() assert(nil) end))                      -- false assertion failed!
do
  local ok, v1, v2 = pcall(function() return assert(1, 2, 3) end)
  show(ok, v1, v2)                                            -- true 1 2 (assert returns all args)
end

-- error re-raised preserves table identity across pcall layers
do
  local sentinel = setmetatable({}, {__tostring = function() return "SENTINEL" end})
  local ok, e = pcall(function()
    local _, inner = pcall(function() error(sentinel) end)
    error(inner)                                              -- re-raise same object
  end)
  show(ok, e == sentinel, tostring(e))                        -- false true SENTINEL
end
