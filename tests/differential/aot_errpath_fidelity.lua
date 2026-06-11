-- Error-path and reflection fidelity (adversarial round 6). Three bug classes:
-- (1) arith slow helpers ran luaO_arith with a STALE L->top.p, so error-path /
--     metamethod pushes clobbered live operand slots: `nil + 1` in a closure
--     reported "arithmetic on a STRING value", and `"hi" + 1` handed the string
--     __add a function as its first operand;
-- (2) Rt_ArithIK conflated the raw numeric op with the MMBIN event: `x - 0`
--     (ADDI x,0 + MMBINI TM_SUB) must compute the ADDITION x + (-0) like lvm.c,
--     observable at x = -0.0;
-- (3) debug.setlocal can falsify any static type proof -> mentioning the debug
--     global disables -O1 type-inference elisions module-wide.

-- (1) error typenames through every operand type, as captured upvalues
local vnil, vbool, vtab, vstr = nil, true, {}, "hi"
print(pcall(function() return vnil + 1 end))
print(pcall(function() return vbool + 1 end))
print(pcall(function() return vtab + 1 end))
print(pcall(function() return vstr + 1 end))   -- string __add coerce fails: 'string' with 'number'
print(pcall(function() return vnil - 1 end))
print(pcall(function() return vnil * 2 end))
print(pcall(function() return vnil / 2 end))
print(pcall(function() return vbool & 1 end))
print(pcall(function() return vtab < 2.0 end))

-- same as plain locals (different operand materialization path)
local lnil = nil
print(pcall(function() return lnil + 1 end))
do
  local x = 1
  if (tonumber("2") or 0) > 100 then x = 1 else x = nil end
  print(pcall(function() return x + 1 end))
  print(type(x))
end

-- string arithmetic must coerce / error exactly like the interpreter
print(pcall(function() return "10" + 1 end))
print(pcall(function() return "10" - 1 end))
print(pcall(function() return "0x10" * 2 end))
print(pcall(function() return "1e2" / 4 end))

-- (2) raw-op vs MMBIN-event: sign-of-zero through the ADDI-encoded subtraction
local nz = -(0.0)
print(nz - 0)        -- 0.0   (ADDI raw path: -0.0 + 0.0)
print(nz - 0.0)      -- -0.0  (SUBK float path: -0.0 - 0.0)
print(nz + 0)        -- 0.0
print(0 - nz)        -- 0.0  (reg-reg)

-- (3) debug.setlocal mutating a parent local: types/branches must match -i
local acc = 1
acc = acc + 1
local function evil() debug.setlocal(2, 1, 9.5) end
evil()
print(acc, math.type(acc), acc + 1)
local s = 5
s = s + 1
local function evil2() debug.setlocal(2, 2, "99") end
evil2()
print(pcall(function() if s < 10 then return "x<10" else return "x>=10" end end))
print(s)

-- step-zero for-loop error message (pcall'd: the message text must match)
print(pcall(function() for i = 1, 3, 0 do end end))
print("done")
