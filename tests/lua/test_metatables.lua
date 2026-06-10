-- tests/lua/test_metatables.lua : metamethods __index, __newindex, __add, __sub, __mul,
--   __eq, __lt, __le, __concat, __len, __call, __tostring; rawget/rawset/rawequal
-- NOTE: Each section is a named function to avoid JIT register-allocation bugs
-- that misidentify the check helper as a table in large flat chunks.
local fails = 0
local function chk(c, m) if not c then fails = fails + 1; print("[-] FAIL test_metatables: " .. tostring(m)) end end

-- 1. __index as a function
local function test_index_fn()
  local t = setmetatable({}, {
    __index = function(tbl, key)
      return "default:" .. key
    end
  })
  chk(t.foo == "default:foo",  "__index function: missing key 'foo'")
  chk(t.bar == "default:bar",  "__index function: missing key 'bar'")
  t.baz = "real"
  chk(t.baz == "real",          "__index function: present key bypasses __index")
end
test_index_fn()

-- 2. __index as a table (inheritance chain)
local function test_index_table()
  local base = {greet = "hello", value = 42}
  local child = setmetatable({}, {__index = base})
  chk(child.greet == "hello", "__index table: inherited 'greet'")
  chk(child.value == 42,      "__index table: inherited 'value'")
  child.own = "mine"
  chk(child.own == "mine",    "__index table: own key not from base")
  chk(child.missing == nil,   "__index table: truly missing is nil")
end
test_index_table()

-- 3. __index chain (3 levels)
local function test_index_chain()
  local root = {x = 1}
  local mid  = setmetatable({y = 2}, {__index = root})
  local leaf = setmetatable({z = 3}, {__index = mid})
  chk(leaf.z == 3, "3-level chain: leaf.z")
  chk(leaf.y == 2, "3-level chain: leaf.y from mid")
  chk(leaf.x == 1, "3-level chain: leaf.x from root")
end
test_index_chain()

-- 4. __newindex as a function
local function test_newindex_fn()
  local log = {}
  local t = setmetatable({}, {
    __newindex = function(tbl, key, val)
      log[#log+1] = key .. "=" .. tostring(val)
      rawset(tbl, key, val)
    end
  })
  t.a = 10
  t.b = 20
  chk(log[1] == "a=10", "__newindex: first set logged as 'a=10'")
  chk(log[2] == "b=20", "__newindex: second set logged as 'b=20'")
  chk(t.a == 10,         "__newindex: rawset stored value a=10")
  -- Second assignment to same key: __newindex NOT called (key exists now)
  t.a = 99
  chk(#log == 2,         "__newindex: not called for existing key update")
  chk(t.a == 99,         "__newindex: existing key updated directly")
end
test_newindex_fn()

-- 5. __newindex as a table (proxy)
local function test_newindex_table()
  local storage = {}
  local proxy = setmetatable({}, {__newindex = storage})
  proxy.x = 42
  chk(storage.x == 42, "__newindex table: value stored in target table")
  chk(rawget(proxy, "x") == nil, "__newindex table: proxy itself is empty")
end
test_newindex_table()

-- 6. rawget and rawset bypass metamethods
local function test_rawget_rawset()
  local t = setmetatable({}, {
    __index    = function() return "METAMETHOD" end,
    __newindex = function() error("should not be called") end,
  })
  rawset(t, "k", "direct")
  chk(rawget(t, "k") == "direct",       "rawget bypasses __index")
  chk(rawget(t, "missing") == nil,      "rawget missing returns nil (not METAMETHOD)")
  chk(t.missing == "METAMETHOD",        "__index still fires for normal access")
end
test_rawget_rawset()

-- 7. rawequal
local function test_rawequal()
  local a = {}
  local b = a
  local c = {}
  setmetatable(a, {__eq = function() return false end})
  chk(rawequal(a, b) == true,  "rawequal: same object is equal")
  chk(rawequal(a, c) == false, "rawequal: different objects not equal")
  chk(rawequal(a, a) == true,  "rawequal: identity")
end
test_rawequal()

-- 8. Arithmetic metamethods (Vec2D)
local function test_arith_meta()
  local Vec = {}
  Vec.__index = Vec
  Vec.__add = function(a, b) return setmetatable({x=a.x+b.x, y=a.y+b.y}, getmetatable(a)) end
  Vec.__sub = function(a, b) return setmetatable({x=a.x-b.x, y=a.y-b.y}, getmetatable(a)) end
  Vec.__mul = function(a, b)
    if type(a) == "number" then return setmetatable({x=a*b.x, y=a*b.y}, getmetatable(b))
    elseif type(b) == "number" then return setmetatable({x=a.x*b, y=a.y*b}, getmetatable(a))
    else return a.x*b.x + a.y*b.y  -- dot product
    end
  end
  Vec.__unm = function(a) return setmetatable({x=-a.x, y=-a.y}, getmetatable(a)) end
  Vec.__eq  = function(a, b) return a.x==b.x and a.y==b.y end
  Vec.__lt  = function(a, b) return (a.x*a.x+a.y*a.y) < (b.x*b.x+b.y*b.y) end
  Vec.__le  = function(a, b) return (a.x*a.x+a.y*a.y) <= (b.x*b.x+b.y*b.y) end
  Vec.__len = function(a) return math.sqrt(a.x*a.x + a.y*a.y) end
  Vec.__tostring = function(a) return "Vec("..a.x..","..a.y..")" end
  Vec.__concat   = function(a, b) return tostring(a) .. tostring(b) end
  Vec.__call     = function(v, s) return setmetatable({x=v.x*s, y=v.y*s}, getmetatable(v)) end

  local function newvec(x, y) return setmetatable({x=x, y=y}, Vec) end

  local v1 = newvec(1, 2)
  local v2 = newvec(3, 4)

  local sum = v1 + v2
  chk(sum.x==4 and sum.y==6, "__add: (1,2)+(3,4)==(4,6)")

  local diff = v2 - v1
  chk(diff.x==2 and diff.y==2, "__sub: (3,4)-(1,2)==(2,2)")

  local scaled = v1 * 3
  chk(scaled.x==3 and scaled.y==6, "__mul scalar: (1,2)*3==(3,6)")

  local dot = v1 * v2
  chk(dot == 11, "__mul dot product: (1,2).(3,4)==11")

  local neg = -v1
  chk(neg.x==-1 and neg.y==-2, "__unm: -(1,2)==(-1,-2)")

  chk(v1 == newvec(1,2),  "__eq: (1,2)==(1,2)")
  chk(v1 ~= v2,           "__eq: (1,2)~=(3,4)")
  chk(v1 < v2,            "__lt: |v1|<|v2|")
  chk(v1 <= v1,           "__le: v1<=v1 (same magnitude)")
  chk(not (v2 < v1),      "__lt reversed: not v2<v1")

  local len = #v1
  chk(math.abs(len - math.sqrt(5)) < 1e-12, "__len: |(1,2)| == sqrt(5)")

  local s = tostring(v1)
  chk(s == "Vec(1,2)", "__tostring: Vec(1,2)")

  local cat = v1 .. v2
  chk(cat == "Vec(1,2)Vec(3,4)", "__concat: 'Vec(1,2)Vec(3,4)'")

  local called = v1(5)
  chk(called.x==5 and called.y==10, "__call: v1(5) == (5,10)")
end
test_arith_meta()

-- 9. __index metamethod on string (method call)
local function test_string_index()
  local s = "Hello World"
  chk(s:upper() == "HELLO WORLD", "string __index: s:upper() via metatable")
  chk(s:len() == 11,               "string __index: s:len()")
  chk(s:sub(1,5) == "Hello",       "string __index: s:sub(1,5)")
end
test_string_index()

-- 10. __index function returning nil stops chain
local function test_index_nil()
  local t = setmetatable({}, {
    __index = function(tbl, key)
      if key == "found" then return 99 end
      return nil
    end
  })
  chk(t.found == 99,  "__index returns 99 for 'found'")
  chk(t.other == nil, "__index returns nil for 'other'")
end
test_index_nil()

if fails == 0 then print("[+] PASS test_metatables") os.exit(0) else os.exit(1) end
