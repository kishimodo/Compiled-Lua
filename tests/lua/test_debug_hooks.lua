-- tests/lua/test_debug_hooks.lua : debug.sethook hooks must fire under the JIT
-- (via the hook-aware interpreter fallback) for functions entered after the
-- hook is set, and OP_FORPREP must raise Lua-5.4-exact error text. Both were
-- gaps the conformance differential surfaced (fixed 2026-06-07).
local name = "test_debug_hooks"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. m) end end

-- call hook fires for a function entered after the hook is set
do
  local calls = 0
  debug.sethook(function() calls = calls + 1 end, "c", 0)
  local function f(n) local s = 0 for i = 1, n do s = s + i end return s end
  local s = f(1000)
  debug.sethook()
  ok(calls > 0, "call hook fires for a called function")
  ok(s == 500500, "hooked function still computes correctly")
end

-- line hook fires
do
  local lines = 0
  debug.sethook(function() lines = lines + 1 end, "l", 0)
  local function g() local a = 1; local b = 2; return a + b end
  local r = g()
  debug.sethook()
  ok(lines > 0, "line hook fires")
  ok(r == 3, "line-hooked function returns correctly")
end

-- count hook fires
do
  local n = 0
  debug.sethook(function() n = n + 1 end, "", 100)
  local function h(k) local s = 0 for i = 1, k do s = s + i end return s end
  h(100000)
  debug.sethook()
  ok(n > 0, "count hook fires")
end

-- FORPREP error text matches Lua 5.4 ("bad 'for' <what> (number expected, got <type>)")
local function ferr(f) local _, e = pcall(f); return (tostring(e):gsub("^[^\n]-:%d+: ", "")) end
ok(ferr(function() for i = "x", 10 do end end)  == "bad 'for' initial value (number expected, got string)", "for initial-value error text")
ok(ferr(function() for i = 1, {}, 1 do end end)  == "bad 'for' limit (number expected, got table)",          "for limit error text")
ok(ferr(function() for i = 1, 10, "z" do end end) == "bad 'for' step (number expected, got string)",          "for step error text")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
