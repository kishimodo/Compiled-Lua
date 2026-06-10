-- tests/lua/test_jit_regressions.lua : permanent regression tests for JIT codegen
-- bugs that this suite's differential layer found and that were fixed 2026-06-07.
-- (Previously these were XFAILs in jit_known_bugs.lua.) See docs/known-bugs-2026-06-07.md.
local name = "test_jit_regressions"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. m) end end

-- JIT-001: a <close> variable in scope at `return` must NOT drop the return value.
local function with_close()
  local g <close> = setmetatable({}, { __close = function() end })
  return 42
end
ok(with_close() == 42, "JIT-001: <close> var in scope at return preserves the value")
local function multi_close()
  local a <close> = setmetatable({}, { __close = function() end })
  return 1, 2, 3
end
local x, y, z = multi_close()
ok(x == 1 and y == 2 and z == 3, "JIT-001: multi-value return through <close>")

-- JIT-002: NaN comparisons are false per IEEE-754 (the `>`/`>=` lowering bug).
local nan = 0 / 0
ok((nan > 0) == false,  "JIT-002: nan > 0 is false")
ok((nan >= 0) == false, "JIT-002: nan >= 0 is false")
ok((nan < 0) == false,  "JIT-002: nan < 0 is false")
ok((5 > 3) == true and (3 > 5) == false,  "JIT-002: ordinary > still correct")
ok((5 >= 5) == true and (4 >= 5) == false, "JIT-002: ordinary >= still correct")
ok((2.5 > 2) == true and (1.5 > 2) == false, "JIT-002: float > still correct")

-- JIT-003: proper tail-call optimization -- deep tail recursion must not crash.
local function loop(n, acc) if n == 0 then return acc end return loop(n - 1, acc + n) end
ok(loop(1000000, 0) == 500000500000, "JIT-003: deep self tail recursion (1e6)")
local even, odd
function even(n) if n == 0 then return true end return odd(n - 1) end
function odd(n) if n == 0 then return false end return even(n - 1) end
ok(even(1000000) == true,  "JIT-003: deep mutual tail recursion (even 1e6)")
ok(odd(999999) == true,    "JIT-003: deep mutual tail recursion (odd)")
-- tail call propagating multiple values
local function pair() return 10, 20 end
local function tailpair() return pair() end
local a, b = tailpair()
ok(a == 10 and b == 20, "JIT-003: multi-value tail call propagates results")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
