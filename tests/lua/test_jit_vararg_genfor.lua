-- test_jit_vararg_genfor.lua : regression for JIT-VARARG-001 (fixed).
--
-- Forwarding `...` (a multret OP_VARARG) or `return ...` immediately after a
-- GENERIC-for loop (pairs/ipairs -> OP_TFORCALL/TFORLOOP) used to expand EXTRA
-- trailing values under the JIT. Root cause: a generic-for creates a
-- to-be-closed slot, so the compiler sets the k (close) flag on the function's
-- terminal OP_TAILCALL/OP_RETURN; the JIT emitted Rt_Close BEFORE the
-- multret consumer, and Rt_Close raised L->top to the frame ceiling (CLOSEKTOP
-- scratch for __close) without restoring it -- so the consumer counted the dead
-- for-loop register slots as extra arguments. Rt_Close now save/restores the
-- logical top around the close, matching the interpreter (which captures the
-- count before closing). A numeric for-loop has no TBC slot, so it never
-- triggered this. Runs under the JIT (default); a failure means the bug is back.
local name = "test_jit_vararg_genfor"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. tostring(m)) end end

-- `...` count after a pairs loop equals the real argument count.
local function count_after_pairs(...)
  local t = { a = 1, b = 2, c = 3 }
  for _ in pairs(t) do end
  return select("#", ...)
end
ok(count_after_pairs(1, 9, 4) == 3, "select('#',...) after pairs-loop == 3")
ok(count_after_pairs() == 0, "select('#',...) after pairs-loop with no args == 0")
ok(count_after_pairs(1, 2, 3, 4, 5) == 5, "select('#',...) after pairs-loop == 5")

-- Forwarding `...` to a function after a pairs loop passes the right args.
local function fwd_after_pairs(...)
  local t = { x = 1, y = 2 }
  for _ in pairs(t) do end
  return math.max(...)
end
ok(fwd_after_pairs(1, 9, 4) == 9, "math.max(...) after pairs-loop == 9")

-- `return ...` (multret return) after a pairs loop returns the right count.
local function ret_after_pairs(...)
  local t = { p = 1, q = 2, r = 3 }
  for _ in pairs(t) do end
  return ...
end
ok(select("#", ret_after_pairs(1, 9, 4)) == 3, "return ... after pairs-loop yields 3 values")
ok((select(2, pcall(function() return (ret_after_pairs(7, 8)) end))) == 7, "return ... first value == 7")

-- ipairs (also a generic-for) behaves the same.
local function fwd_after_ipairs(...)
  local t = { 10, 20, 30 }
  for _ in ipairs(t) do end
  return select("#", ...)
end
ok(fwd_after_ipairs(1, 9, 4) == 3, "select('#',...) after ipairs-loop == 3")

-- Combined: a real <close> variable AND a generic-for, forwarding `...`. The
-- __close must run exactly once and the multret count must still be correct.
local closed = 0
local function close_and_pairs(...)
  local x <close> = setmetatable({}, { __close = function() closed = closed + 1 end })
  for _ in pairs({ a = 1 }) do end
  return select("#", ...)
end
ok(close_and_pairs(1, 9, 4) == 3, "<close> + pairs + multret: count == 3")
ok(closed == 1, "<close> + pairs + multret: __close ran exactly once")

-- Control: numeric for stays correct (never affected).
local function count_after_numfor(...)
  for _ = 1, 3 do end
  return select("#", ...)
end
ok(count_after_numfor(1, 9, 4) == 3, "numeric-for control == 3")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
