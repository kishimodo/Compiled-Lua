-- AOT differential: functions declared but never called must not change
-- observable behaviour when the -O2 reachability pass (lc_pass_dead_global)
-- runs over them. The pass is DATA ONLY today -- it records LcFunc.dead
-- but codegen still emits every function. This test locks in that
-- byte-for-byte stdout stays identical to the interpreter across
-- -O0/-O1/-O2.
--
-- Shape: a mix of called and never-called functions, plus a mutual
-- recursion pair, plus a leaf function that is only reachable through an
-- uncalled caller. Even when the pass DOES mark some of them dead
-- internally, observable behaviour must not change because codegen still
-- emits the bodies today.

local function never_called_helper1()
  return "one"
end

local function never_called_helper2()
  return never_called_helper1() .. " and two"
end

local function called_helper(x)
  return x * 2 + 1
end

local function mutual_a(n)
  if n <= 0 then return "a-done" end
  return mutual_b(n - 1)
end
function mutual_b(n)
  if n <= 0 then return "b-done" end
  return mutual_a(n - 1)
end

print(called_helper(3), called_helper(0), called_helper(-2))
print(mutual_a(4), mutual_b(5))
print(type(never_called_helper1), type(never_called_helper2))
