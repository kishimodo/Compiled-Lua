-- close_upvalue_stale.lua : regression for a JIT register-caching bug around
-- to-be-closed (<close>) variables, found by the conformance differential and
-- FIXED 2026-06-07 (Lower_Close now reloads the register cache after Rt_Close,
-- since __close runs arbitrary Lua that can mutate captured upvalues). JIT and
-- interpreter must now produce identical output.
--
-- Setup: a local `got` is captured by a __close handler; the <close> block exits
-- normally (so __close RUNS and assigns got = "closed" -- proven by the CLOSE-RAN
-- line, which matches under both engines). But when `got` is then read and passed
-- as an argument to a *Lua* function call (show(got)) on the next statement, the
-- JIT uses a STALE register copy of `got` captured before the block closed, so it
-- prints "unset" instead of "closed". The interpreter (oracle) prints "closed".
--
-- Discriminators found while minimizing:
--   * reading `got` via `print(got)` directly DOES reload -> matches (so the bug is
--     specific to the argument-marshaling path of a Lua-defined call here);
--   * reading `got` via "..".."got" concatenation DOES reload -> matches;
--   * a preceding plain local (number) does NOT trigger it; the function local does.
-- Net effect: an __close-mutated upvalue is observed stale. Real JIT codegen bug.

local function show(x) print(x) end

local got = "unset"
do
  local guard <close> = setmetatable({}, {
    __close = function() got = "closed"; print("CLOSE-RAN") end,
  })
end
show(got)        -- interpreter: closed   |   JIT: unset  (stale upvalue register)
