-- tests/differential/tailcall.lua : deep proper tail recursion and tail call returning a table
-- Both JIT and interpreter must produce byte-identical stdout.

-- 1. Deep tail-recursive sum: sum(n, acc) = sum(n-1, acc+n), tail call
local function sum(n, acc)
  if n == 0 then return acc end
  return sum(n - 1, acc + n)
end
-- The JIT now implements proper TCO (a tail-call drive loop in Rt_TailCall), so
-- these run in constant native stack -- depth 1e6 would have crashed the JIT
-- before the 2026-06-07 fix. Both backends must agree.
print(sum(1000000, 0))   -- 500000500000

-- 2. Deep tail-recursive countdown: tests tail call depth
local function countdown(n)
  if n == 0 then return "done" end
  return countdown(n - 1)
end
print(countdown(1000000))   -- "done"

-- 3. Tail call step-by-2 (even check simulation)
local function step2(n)
  if n <= 0 then return n end
  return step2(n - 2)
end
print(step2(1000000))   -- 0
print(step2(999999))    -- -1

-- 4. Tail call that returns a table
local function make_table(n)
  if n <= 0 then return {result = 0, msg = "zero"} end
  if n == 1 then return {result = 1, msg = "one"} end
  return make_table(n - 1)
end
local t = make_table(5000)
print(t.result, t.msg)   -- 1   one

-- 5. Tail call returning multiple values
local function multi_return(n, a, b)
  if n == 0 then return a, b end
  return multi_return(n - 1, a + 1, b + 2)
end
local x, y = multi_return(1000, 0, 0)
print(x, y)   -- 1000   2000

-- 6. Tail call accumulator building a list
local function build_list(n, acc)
  if n == 0 then return acc end
  acc[#acc+1] = n
  return build_list(n - 1, acc)
end
local lst = build_list(10, {})
print(lst[1], lst[10])   -- 10   1
