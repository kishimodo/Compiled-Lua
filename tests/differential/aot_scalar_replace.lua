-- Differential: -O3 escape analysis + scalar replacement must stay byte-exact
-- with the interpreter (which never scalar-replaces). The runner compiles this
-- at O0/O1/O2/O3 and diffs stdout against clua-interp.exe -i. The interesting
-- column is O3, where lc_pass_scalar_replace fires.
--
-- NOTE: slice 1 is single-home-definition (sound-conservative): a table's home
-- register must not be reused elsewhere in its function. So each scenario lives
-- in its OWN function (a dedicated register), which is the realistic pattern and
-- the firing path. Bundling them in one main chunk would reuse a register and
-- (correctly) bail every candidate.
--
-- Spec: docs/superpowers/specs/2026-06-13-scalar-replacement-o3-design.md

-- 1. basic struct, string keys (fires)
local function f_struct(a, b)
  local t = {}
  t.x = a
  t.y = b
  return t.x + t.y
end
print("struct", f_struct(10, 32))

-- 2. integer keys (fires; GETI/SETI)
local function f_ints()
  local a = {}
  a[1] = 100
  a[2] = 200
  a[3] = a[1] + a[2]
  return a[1], a[2], a[3]
end
print("ints", f_ints())

-- 3. mixed string + integer keys (separate key namespaces), read-modify-write
local function f_mixed()
  local m = {}
  m.k = 5
  m[1] = 6
  m.k = m.k + m[1]
  return m.k, m[1]
end
print("mixed", f_mixed())

-- 4. read an unset key -> nil (slots LOADNIL'd at birth)
local function f_unset()
  local u = {}
  u.a = 1
  return u.a, tostring(u.b), tostring(u[7])
end
print("unset", f_unset())

-- 5. set a key to nil, then read it -> nil (raw remove semantics)
local function f_setnil()
  local n = {}
  n.x = 5
  n.x = nil
  return tostring(n.x)
end
print("setnil", f_setnil())

-- 6. constant values (SET with a constant -> LOADK path)
local function f_consts()
  local c = {}
  c.i = 42
  c.s = "hi"
  c.f = 3.5
  c.b = true
  return c.i, c.s, c.f, c.b
end
print("consts", f_consts())

-- 7. loop reuse: a fresh table each iteration (the per-iteration alloc the pass
--    removes). The value must not leak across iterations.
local function f_loop(n)
  local s = 0
  for i = 1, n do
    local p = {}
    p.a = i
    p.b = i * 2
    s = s + p.a + p.b
  end
  return s
end
print("loop", f_loop(1000))

-- 8. GC stress: a scalar-replaced table's fields must survive a full GC mid
--    function (the reserved slots live inside the frame, scanned like locals).
local function f_gc(n)
  local sum = 0
  for i = 1, n do
    local r = {}
    r.a = i
    r.b = i + 1
    collectgarbage("collect")
    local junk = { i, i, i }   -- heap pressure; escapes (SETLIST) -> stays real
    sum = sum + r.a + r.b + #junk
  end
  return sum
end
print("gcstress", f_gc(400))

-- 9. MUST NOT FIRE (bail) -- still byte-exact because the table stays real:

-- 9a. escaping table (returned)
local function f_escape(v)
  local e = {}
  e.v = v
  return e
end
print("escape", f_escape(7).v, f_escape(11).v)

-- 9b. variable (non-constant) key -> bail
local function f_varkey()
  local vk = {}
  local key = "dyn"
  vk[key] = 9
  vk[key] = vk[key] + 1
  return vk[key], vk.dyn
end
print("varkey", f_varkey())

-- 9c. metatable via setmetatable (a call -> escape -> bail; metamethod works)
local function f_meta()
  local mt = setmetatable({}, { __index = function() return 99 end })
  mt.real = 1
  return mt.real, mt.missing
end
print("meta", f_meta())

-- 9d. length operator observes shape -> bail
local function f_length()
  local len = {}
  len[1] = 1; len[2] = 2; len[3] = 3
  return #len
end
print("length", f_length())

-- 9e. table passed to a function -> escape -> bail
local function sum2(tb) return tb.a + tb.b end
local function f_passed()
  local pt = {}
  pt.a = 4
  pt.b = 5
  return sum2(pt)
end
print("passed", f_passed())

-- 9f. back-edge GC (regression: scalar-replace soundness attack). A `goto`
--     re-reads a field AFTER a collectgarbage whose pc is textually past the
--     last read; the live-range check must follow the back-edge and bail, or
--     the reserved above-top slot gets niled by GC. Must stay a real table.
local function f_backedge()
  local fresh = { v = 1234 }
  local t = {}
  t.keep = fresh
  local count = 0
  local sum = 0
  ::read::
  sum = sum + t.keep.v
  if count >= 3 then goto done end
  collectgarbage("collect")
  count = count + 1
  goto read
  ::done::
  return sum
end
print("backedge", f_backedge())

-- 9g. table created OUTSIDE a loop, read INSIDE across the back-edge + a GC
--     safepoint -> slot live across the edge -> must bail.
local function f_outside_loop(n)
  local box = {}
  box.acc = 0
  local i = 0
  while i < n do
    i = i + 1
    local g = { i, i }            -- heap pressure (escapes)
    box.acc = box.acc + #g
    collectgarbage("step", 0)
  end
  return box.acc
end
print("outsideloop", f_outside_loop(50))

print("done")
