-- tests/lua/test_varargs.lua : select('#',...) and select(n,...); table.pack/unpack; forwarding; nil holes
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_varargs: " .. tostring(m)) end end

-- 1. select('#', ...) counts all args including trailing nils
local function count_args(...)
  return select('#', ...)
end
ok(count_args() == 0,             "select('#') empty == 0")
ok(count_args(1,2,3) == 3,        "select('#') 3 args == 3")
ok(count_args(1,nil,3) == 3,      "select('#') nil in middle == 3")
ok(count_args(1,nil,nil) == 3,    "select('#') trailing nils == 3")
ok(count_args(nil) == 1,          "select('#') single nil == 1")

-- 2. select(n, ...) returns args from n onward
local function from(n, ...)
  return select(n, ...)
end
do
  local a, b, c = from(2, 10, 20, 30, 40)
  ok(a == 20 and b == 30 and c == 40, "select(2,...) returns from index 2")
end
do
  local a = from(1, "x", "y", "z")
  ok(a == "x", "select(1,...) first element")
end
do
  local a, b = from(3, 1, 2, 3, 4, 5)
  ok(a == 3 and b == 4, "select(3,...) returns 3,4,...")
end
-- Negative index counts from end
do
  local a = from(-1, 10, 20, 30)
  ok(a == 30, "select(-1,...) last element")
end
do
  local a, b = from(-2, 10, 20, 30)
  ok(a == 20 and b == 30, "select(-2,...) last two elements")
end

-- 3. table.pack preserves count with n field
do
  local t = table.pack(1, nil, 3, nil)
  ok(t.n == 4,    "table.pack with nil holes: n==4")
  ok(t[1] == 1,   "table.pack t[1]==1")
  ok(t[2] == nil, "table.pack t[2]==nil")
  ok(t[3] == 3,   "table.pack t[3]==3")
  ok(t[4] == nil, "table.pack t[4]==nil")
end

do
  local t2 = table.pack()
  ok(t2.n == 0, "table.pack() empty: n==0")
end

do
  local t3 = table.pack("a", "b", "c")
  ok(t3.n == 3 and t3[1] == "a" and t3[3] == "c", "table.pack strings")
end

-- 4. table.unpack
do
  local t = {10, 20, 30, 40, 50}
  local a, b, c, d, e = table.unpack(t)
  ok(a==10 and b==20 and c==30 and d==40 and e==50, "table.unpack full")
end
do
  local t = {10, 20, 30, 40, 50}
  local b, c, d = table.unpack(t, 2, 4)
  ok(b==20 and c==30 and d==40, "table.unpack with range 2..4")
end
do
  local t = {"x"}
  local v = table.unpack(t)
  ok(v == "x", "table.unpack single element")
end
do
  local t = {}
  local v = table.unpack(t)
  ok(v == nil, "table.unpack empty table returns nil")
end

-- 5. Forwarding ... through calls
local function double(...)
  local t = table.pack(...)
  for i = 1, t.n do t[i] = t[i] * 2 end
  return table.unpack(t, 1, t.n)
end
do
  local a, b, c = double(3, 4, 5)
  ok(a==6 and b==8 and c==10, "forwarding ... through double()")
end

local function wrap_forward(...)
  return double(...)
end
do
  local a, b = wrap_forward(7, 8)
  ok(a==14 and b==16, "forwarding ... through wrap_forward")
end

-- 6. Varargs in nested function
local function outer(...)
  local args = {...}
  local function inner()
    return table.unpack(args)
  end
  return inner()
end
do
  local a, b, c = outer(100, 200, 300)
  ok(a==100 and b==200 and c==300, "varargs captured via table in closure")
end

-- 7. select('#') on forwarded varargs
local function count_fwd(...)
  return count_args(...)
end
ok(count_fwd(1,2,3) == 3,       "select('#') on forwarded varargs == 3")
ok(count_fwd(nil,nil) == 2,     "select('#') forwarded nils == 2")

-- 8. table.pack round-trip with nil holes using n
local function packtest(...)
  local t = table.pack(...)
  local result = {}
  for i = 1, t.n do result[i] = t[i] end
  return t.n, result
end
do
  local n, r = packtest(10, nil, 30)
  ok(n == 3,        "packtest n==3 with nil hole")
  ok(r[1] == 10,    "packtest r[1]==10")
  ok(r[2] == nil,   "packtest r[2]==nil (hole)")
  ok(r[3] == 30,    "packtest r[3]==30")
end

-- 9. Multiple returns as varargs
local function multi() return 1, 2, 3 end
local function use_multi(...)
  return select('#', ...)
end
ok(use_multi(multi()) == 3, "multiple returns as varargs: count==3")

-- 10. Varargs count with table.pack of multiple return values
do
  local t = table.pack(multi())
  ok(t.n == 3 and t[1]==1 and t[2]==2 and t[3]==3, "table.pack of multiple returns")
end

if fails == 0 then print("[+] PASS test_varargs") os.exit(0) else os.exit(1) end
