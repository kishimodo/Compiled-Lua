-- tests/differential/vararg.lua : vararg forwarding + select; print results
-- Both JIT and interpreter must produce byte-identical stdout.

-- 1. select('#', ...) counting
local function count(...)
  return select('#', ...)
end
print(count())                -- 0
print(count(1, 2, 3))         -- 3
print(count(1, nil, 3))       -- 3
print(count(nil, nil, nil))   -- 3

-- 2. select(n, ...) returning from index
local function from(n, ...)
  return select(n, ...)
end
print(from(1, "a", "b", "c"))   -- a   b   c
print(from(2, "a", "b", "c"))   -- b   c
print(from(3, "a", "b", "c"))   -- c
print(from(-1, "x", "y", "z"))  -- z

-- 3. table.pack and table.unpack
local t1 = table.pack(10, 20, 30, nil, 50)
print(t1.n, t1[1], t1[2], t1[3], t1[4], t1[5])  -- 5  10  20  30  nil  50

local t2 = {5, 10, 15, 20, 25}
print(table.unpack(t2))          -- 5  10  15  20  25
print(table.unpack(t2, 2, 4))    -- 10  15  20

-- 4. Forwarding varargs through nested calls
local function double_all(...)
  local t = table.pack(...)
  local out = {}
  for i = 1, t.n do
    out[i] = (t[i] ~= nil) and (t[i] * 2) or false
  end
  return table.unpack(out, 1, t.n)
end

local function relay(...)
  return double_all(...)
end

print(relay(1, 2, 3, 4, 5))   -- 2  4  6  8  10

-- 5. Varargs in tail position
local function identity(...)
  return ...
end
local function passthrough(...)
  return identity(...)
end
print(passthrough(7, 8, 9))   -- 7  8  9

-- 6. Vararg count via select in a loop
local function sum_varargs(...)
  local n = select('#', ...)
  local s = 0
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == "number" then s = s + v end
  end
  return s
end
print(sum_varargs(1, 2, 3, 4, 5))      -- 15
print(sum_varargs(10, nil, 20, nil, 5)) -- 35

-- 7. table.pack of multiple-return function
local function three_vals() return 100, 200, 300 end
local tp = table.pack(three_vals())
print(tp.n, tp[1], tp[2], tp[3])   -- 3  100  200  300

-- 8. Varargs passed to string.format
local function fmt(template, ...)
  return string.format(template, ...)
end
print(fmt("%d + %d = %d", 3, 4, 7))   -- 3 + 4 = 7
print(fmt("(%s, %s)", "hello", "world"))  -- (hello, world)

-- 9. Nil holes with explicit n from table.pack
local function echo_with_nils(...)
  local t = table.pack(...)
  local parts = {}
  for i = 1, t.n do
    parts[i] = tostring(t[i])
  end
  return table.concat(parts, "|")
end
print(echo_with_nils(1, nil, 3, nil, 5))   -- 1|nil|3|nil|5

-- 10. Vararg forwarding preserves nil holes
local function wrap_echo(...)
  return echo_with_nils(...)
end
print(wrap_echo(10, nil, 30))   -- 10|nil|30
