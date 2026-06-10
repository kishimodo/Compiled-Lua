-- compare_meta_stale.lua : regression for a JIT register-cache staleness bug in
-- the comparison opcodes' slow paths -- OP_EQ/LT/LE (register form,
-- EmitCompareAndBranch) and OP_EQI/LTI/LEI/GTI/GEI (immediate form,
-- EmitImmCompareAndBranch).
--
-- When the operands are not both integers the JIT calls a runtime helper
-- (Rt_EqSlow/LtSlow/LeSlow, Rt_*ISlow) which runs luaV_equalobj/lessthan/
-- lessequal; a comparison metamethod is arbitrary Lua (via luaD_call) that can
-- (a) mutate a local of the enclosing function that it captured as an upvalue,
-- and (b) grow/RELOCATE the Lua stack. The JIT caches that local in a callee-
-- saved register; the slow path must reload the register cache AFTER the helper
-- (before its conditional branch) or the subsequent read returns the STALE
-- pre-metamethod value. This is the close_upvalue_stale.lua bug, reached via a
-- comparison instead of __close.
--
-- Deterministic output; the runner diffs JIT vs `-i`. Must be identical.

-- Grow/relocate the Lua stack from inside a metamethod.
local function deep(n)
  if n <= 0 then return 0 end
  local a, b, c, d = n, n + 1, n + 2, n + 3
  return deep(n - 1) + a + b + c + d
end

-- Register form: `p < q` / `p <= q` / `p == q`, two tables. Each metamethod
-- mutates `got` (a local captured as an open upvalue) then relocates the stack.
local function reg_form()
  local got = "initial"
  local mt = {
    __lt = function() deep(400); got = "lt";  return true end,
    __le = function() deep(400); got = "le";  return true end,
    __eq = function() deep(400); got = "eq";  return true end,
  }
  local p = setmetatable({}, mt)
  local q = setmetatable({}, mt)
  if p <  q then end   -- OP_LT  slow -> __lt: got="lt",  stack relocates
  local after_lt = got
  if p <= q then end   -- OP_LE  slow -> __le: got="le"
  local after_le = got
  if p == q then end   -- OP_EQ  slow -> __eq: got="eq"
  return after_lt .. "," .. after_le .. "," .. got
end

-- Immediate form: `p < 5` etc. (table vs int literal) routes through LTI/LEI/
-- GTI/GEI slow helpers.
local function imm_form()
  local got = "initial"
  local mt = {
    __lt = function() deep(400); got = "lt"; return true end,
    __le = function() deep(400); got = "le"; return true end,
  }
  local p = setmetatable({}, mt)
  if p <  5 then end   -- LTI -> __lt(p,5): got="lt"
  local a = got
  if p <= 5 then end   -- LEI -> __le(p,5): got="le"
  local b = got
  if p >  5 then end   -- GTI -> __lt(5,p): got="lt"
  local c = got
  if p >= 5 then end   -- GEI -> __le(5,p): got="le"
  return a .. "," .. b .. "," .. c .. "," .. got
end

print(reg_form())   -- expect: lt,le,eq
print(imm_form())   -- expect: lt,le,lt,le
