-- aot_debughooks.lua — a program that MENTIONS debug links the full bytecode
-- interpreter (the "debug" constant scan keeps lvm.o in), so debug.sethook
-- works in the compiled exe exactly like under luavm -i: functions entered
-- while a hook is active route through the hook-aware interpreter.
--
-- This also pins the interpreter-strip feature from the other side: if the
-- no-interp lvm variant were ever wrongly linked into a debug-using program,
-- the first hooked call would raise instead of running, and this diff fails.

local calls = 0
debug.sethook(function() calls = calls + 1 end, "c")

local function f(a) return a * 2 + 1 end
local function g(b)
  local acc = 0
  for i = 1, b do acc = acc + f(i) end
  return acc
end

local r = g(10)
debug.sethook()

print("result", r)
print("hooks fired", calls > 0)

-- getinfo through the debug library (reads the blob-shipped debug info)
local info = debug.getinfo(f, "S")
print("what", info.what)
print("traceback is function", type(debug.traceback) == "function")
