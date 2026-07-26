-- Deep non-tail recursion must raise a CATCHABLE Lua error, not kill the process.
--
-- AOT code makes a real native call for every Lua-level call, so Lua recursion
-- consumes native stack; the interpreter runs every callee in one C frame and is
-- bounded only by LUAI_MAXSTACK. Before the guard in Rt_Call, a compiled binary
-- died between depth 9,000 and 15,000 with an unhandled STATUS_STACK_OVERFLOW
-- (0xC00000FD) -- no message, not catchable by pcall, nothing printed. The
-- interpreter reached 200,000 and returned "<chunk>:<line>: stack overflow".
--
-- That crash was invisible because no test went deep enough:
-- tests/differential/pcall_err.lua:85-95 deliberately recurses only 500 levels.
--
-- What this test pins:
--   * unbounded recursion produces the SAME message under both engines, so the
--     compiled binary and the oracle agree byte-for-byte;
--   * the error is catchable and the program keeps running afterwards;
--   * depths that used to crash (10,000 / 20,000) now complete normally.
--
-- Depths are kept well clear of the actual limit ON PURPOSE. The compiled limit
-- is finite (16 MB of reserved stack, ~93,000 frames) where the interpreter's is
-- ~1,000,000, so a depth chosen between the two would legitimately diverge. This
-- test asserts the shape of the behaviour, not the exact depth at which it flips.

local function rec(n)
  if n <= 0 then return 0 end
  return 1 + rec(n - 1)   -- NOT a tail call: the addition happens after
end

-- Depths that used to be fatal.
for _, depth in ipairs({ 1000, 10000, 20000 }) do
  local ok, res = pcall(rec, depth)
  print(string.format("depth %-6d ok=%-5s result=%s", depth, tostring(ok),
                      ok and tostring(res) or "ERR"))
end

-- Unbounded recursion: must be a catchable error with the standard message.
local function forever(n) return 1 + forever(n + 1) end
local ok, err = pcall(forever, 1)
print("unbounded ok=" .. tostring(ok))
print("unbounded err=" .. tostring(err):gsub("^.*:%d+: ", ""))

-- The state must still be usable after catching it: a stack-overflow error that
-- left the Lua stack or CallInfo chain inconsistent would show up here.
local ok2, res2 = pcall(rec, 100)
print("after recovery ok=" .. tostring(ok2) .. " result=" .. tostring(res2))

-- And a second overflow must behave identically to the first, which is what
-- catches a guard that latches or a counter that ratchets and never resets.
local ok3, err3 = pcall(forever, 1)
print("second unbounded ok=" .. tostring(ok3))
print("second unbounded err=" .. tostring(err3):gsub("^.*:%d+: ", ""))

print("SURVIVED")
