-- settable_meta_stale.lua : regression for a JIT register-cache staleness bug
-- in the SET opcodes (OP_SETI / OP_SETFIELD / OP_SETTABLE / OP_SETTABUP).
--
-- Each of these lowerings calls a runtime helper (Rt_SetI/SetField/SetTable/
-- SetTabUp) which runs luaV_finishset; on a __newindex metamethod that in turn
-- calls luaD_call -- arbitrary Lua that can grow and RELOCATE the Lua stack.
-- The JIT keeps base (RDI) and the hottest locals in callee-saved registers for
-- the whole function body, so after a relocation those are STALE: reading a
-- cached local returns an old value and writing through the stale base lands in
-- freed memory (use-after-free). The fix reloads RDI + the register cache after
-- each Rt_Set* (mirroring the GET twins and Lower_Close).
--
-- This script prints deterministically; the test runner runs it under the JIT
-- and under `-i` (interpreter oracle) and diffs stdout. Before the fix the two
-- diverged; after it they must be identical.

-- Force the Lua stack to grow/relocate from inside a metamethod.
local function deep(n)
  if n <= 0 then return 0 end
  local a, b, c, d = n, n + 1, n + 2, n + 3
  return deep(n - 1) + a + b + c + d
end

local relocating = { __newindex = function(_, _, _) deep(500) end }
local t  = setmetatable({}, relocating)
local up = setmetatable({}, relocating)   -- captured as an upvalue below

local function f()
  -- `hot`/`acc` are referenced repeatedly so the allocator caches them in the
  -- callee-saved pool (R12-R15/RSI) that the relocation would otherwise stale.
  local hot = 12345
  local acc = 0
  for _ = 1, 4 do acc = acc + hot end     -- 12345 * 4 = 49380

  t[1]      = 7        -- OP_SETI     -> __newindex -> deep() relocates the stack
  t.field   = 8        -- OP_SETFIELD -> same
  t[acc]    = 9        -- OP_SETTABLE -> same
  up.viaup  = 10       -- OP_SETTABUP -> same (up is an upvalue of f)

  return hot + acc     -- read the cached locals AFTER four relocations
end

print(f())             -- 12345 + 49380 = 61725 on both engines
