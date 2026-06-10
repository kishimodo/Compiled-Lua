-- tests/lua/test_jit_limits.lua : functions that exceed JIT codegen limits must
-- run CORRECTLY via the bytecode-interpreter fallback (lvm.c) instead of
-- crashing. Before 2026-06-07 a >4096-opcode function segfaulted (exit 139) and
-- a >1024-forward-jump function aborted. Runs under the JIT host, so reaching
-- these asserts at all proves the fallback path. Built with load() to avoid a
-- giant literal source. See docs/known-bugs-2026-06-07.md.
local name = "test_jit_limits"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. m) end end

-- >4096 opcodes (5000 statements): used to segfault; must fall back + return 5000.
do
  local b = { "return function() local s=0" }
  for _ = 1, 5000 do b[#b + 1] = "s=s+1" end
  b[#b + 1] = "return s end"
  local f = assert(load(table.concat(b, " ")))()
  ok(f() == 5000, ">4096-opcode function returns correct result via interpreter fallback")
end

-- >1024 forward jumps (1100 if-blocks > MAX_FWD_JUMPS=1024): used to abort.
do
  local b = { "return function(n) local r=0" }
  for i = 1, 1100 do b[#b + 1] = ("if n==%d then r=r+%d end"):format(i, i) end
  b[#b + 1] = "return r end"
  local f = assert(load(table.concat(b, " ")))()
  ok(f(500) == 500,  ">1024-forward-jump function: branch taken at 500")
  ok(f(1100) == 1100, ">1024-forward-jump function: branch taken at 1100")
  ok(f(0) == 0,       ">1024-forward-jump function: no branch taken")
end

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
