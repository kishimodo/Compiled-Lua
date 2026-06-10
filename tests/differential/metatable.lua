-- tests/differential/metatable.lua : operator metamethods; print computed results
-- Both JIT and interpreter must produce byte-identical stdout.

-- 1. __index as function
do
  local t = setmetatable({x=1}, {
    __index = function(tbl, k) return "default_" .. k end
  })
  print(t.x)          -- 1
  print(t.missing)    -- default_missing
  print(t.foo)        -- default_foo
end

-- 2. __index as table (prototypal inheritance)
do
  local proto = {greet = "hello", value = 10}
  local obj = setmetatable({value = 99}, {__index = proto})
  print(obj.value)    -- 99  (own key overrides)
  print(obj.greet)    -- hello
  print(obj.none)     -- nil
end

-- 3. __newindex logging
do
  local log = {}
  local t = setmetatable({}, {
    __newindex = function(tbl, k, v)
      log[#log+1] = k .. "=" .. tostring(v)
      rawset(tbl, k, v)
    end
  })
  t.a = 1
  t.b = 2
  t.a = 3    -- already exists, __newindex not called
  for _, entry in ipairs(log) do print(entry) end  -- a=1, b=2
  print(t.a, t.b)   -- 3  2
end

-- 4. __add
do
  local mt = {
    __add = function(a, b) return setmetatable({v = a.v + b.v}, getmetatable(a)) end,
    __tostring = function(a) return "N(" .. a.v .. ")" end,
  }
  mt.__index = mt
  local function N(x) return setmetatable({v=x}, mt) end
  local r = N(3) + N(4)
  print(tostring(r))    -- N(7)
  print((N(10) + N(20)).v)  -- 30
end

-- 5. __sub, __mul, __unm
do
  local mt = {}
  mt.__index = mt
  mt.__sub = function(a, b) return setmetatable({v = a.v - b.v}, mt) end
  mt.__mul = function(a, b)
    if type(b) == "number" then return setmetatable({v = a.v * b}, mt)
    else return setmetatable({v = a.v * b.v}, mt)
    end
  end
  mt.__unm = function(a) return setmetatable({v = -a.v}, mt) end
  local function M(x) return setmetatable({v=x}, mt) end
  print((M(10) - M(3)).v)    -- 7
  print((M(5) * M(4)).v)     -- 20
  print((M(6) * 3).v)        -- 18
  print((-M(7)).v)           -- -7
end

-- 6. __eq, __lt, __le
do
  local mt = {}
  mt.__eq = function(a, b) return a.v == b.v end
  mt.__lt = function(a, b) return a.v < b.v end
  mt.__le = function(a, b) return a.v <= b.v end
  local function V(x) return setmetatable({v=x}, mt) end
  print(V(5) == V(5))   -- true
  print(V(5) == V(6))   -- false
  print(V(3) < V(5))    -- true
  print(V(5) < V(3))    -- false
  print(V(3) <= V(3))   -- true
  print(V(3) <= V(4))   -- true
  print(V(4) <= V(3))   -- false
end

-- 7. __concat and __len
do
  local mt = {}
  mt.__concat = function(a, b)
    local av = type(a) == "table" and a.v or a
    local bv = type(b) == "table" and b.v or b
    return setmetatable({v = tostring(av) .. tostring(bv)}, mt)
  end
  mt.__len = function(a) return #a.v end
  local function S(s) return setmetatable({v=s}, mt) end
  local r = S("hello") .. S(" world")
  print(r.v)        -- hello world
  print(#S("abc"))  -- 3
  print((S("foo") .. "!").v)   -- foo!
end

-- 8. __tostring and __call
do
  local mt = {}
  mt.__tostring = function(self) return "Point(" .. self.x .. "," .. self.y .. ")" end
  mt.__call = function(self, dx, dy)
    return setmetatable({x=self.x+dx, y=self.y+dy}, mt)
  end
  mt.__index = mt
  local function P(x,y) return setmetatable({x=x,y=y}, mt) end
  local p = P(1,2)
  print(tostring(p))       -- Point(1,2)
  local p2 = p(3, 4)
  print(tostring(p2))      -- Point(4,6)
end

-- 9. rawget, rawset, rawequal
do
  local mt = {
    __index = function() return "INDEX" end,
    __newindex = function(t,k,v) rawset(t,k,v*10) end,
  }
  local t = setmetatable({}, mt)
  t.x = 5             -- __newindex: stores x=50
  print(t.x)          -- 50 (raw access, key exists)
  print(rawget(t,"x"))   -- 50
  print(rawget(t,"y"))   -- nil (not "INDEX")
  rawset(t, "z", 99)
  print(t.z)          -- 99
  local a, b = {}, {}
  setmetatable(a, {__eq = function() return true end})
  print(rawequal(a, a))   -- true
  print(rawequal(a, b))   -- false
end

-- 10. __index chain (3-level prototype)
do
  local base = setmetatable({base_val = 1}, {
    __index = function(t,k) return "base_default" end
  })
  local mid = setmetatable({mid_val = 2}, {__index = base})
  local top = setmetatable({top_val = 3}, {__index = mid})
  print(top.top_val)    -- 3
  print(top.mid_val)    -- 2
  print(top.base_val)   -- 1
  print(top.other)      -- base_default
end
