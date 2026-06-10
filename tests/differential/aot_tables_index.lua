-- AOT differential: table index get/set — field (GETFIELD/SETFIELD), integer
-- index (GETI/SETI), computed key (GETTABLE/SETTABLE), and NEWTABLE. Each form
-- exercises both the const-value and register-value SET encodings (the Ck path).

-- field get/set
local t = {}
t.x = 10
t.y = t.x * 2          -- SETFIELD with a register value (Ck >= 0)
t.name = "lua"         -- SETFIELD with a constant string value (Ck < 0)
print("field", t.x, t.y, t.name)

-- integer index get/set
local a = {}
a[1] = 100
a[2] = 200
a[3] = a[1] + a[2]     -- SETI register value
print("int", a[1], a[2], a[3], #a)

-- computed (variable) key get/set
local m = {}
local k = "key"
m[k] = 42
local k2 = 7
m[k2] = "seven"        -- SETTABLE constant value
print("computed", m[k], m[k2])

-- nested tables (chained GETFIELD)
local n = { a = { b = { c = 7 } } }
print("nested", n.a.b.c)

-- a table built and summed in a loop (tables + numeric-for interplay)
local sq = {}
for i = 1, 6 do sq[i] = i * i end
local s = 0
for i = 1, 6 do s = s + sq[i] end
print("loopsum", s, #sq)
