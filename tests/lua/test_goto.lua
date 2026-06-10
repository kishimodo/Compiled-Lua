-- tests/lua/test_goto.lua : forward and backward goto + labels; loop-continue idiom
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_goto: " .. tostring(m)) end end

-- 1. Forward goto skips code
do
  local x = 0
  goto skip_assign
  x = 99
  ::skip_assign::
  ok(x == 0, "forward goto skips intervening code")
end

-- 2. Forward goto to end of block
do
  local result = "before"
  do
    goto done
    result = "never"
    ::done::
  end
  ok(result == "before", "forward goto to end-of-block label")
end

-- 3. Backward goto (simple loop)
do
  local i = 0
  local sum = 0
  ::loop_top::
  if i >= 5 then goto loop_end end
  i = i + 1
  sum = sum + i
  goto loop_top
  ::loop_end::
  ok(i == 5,   "backward goto loop ran 5 times")
  ok(sum == 15, "backward goto loop sum 1..5 = 15")
end

-- 4. Loop-continue idiom (skip odd numbers)
do
  local evens = {}
  for i = 1, 10 do
    if i % 2 ~= 0 then goto continue end
    evens[#evens+1] = i
    ::continue::
  end
  ok(#evens == 5,    "continue idiom: 5 even numbers collected")
  ok(evens[1] == 2,  "continue idiom: first even is 2")
  ok(evens[5] == 10, "continue idiom: last even is 10")
end

-- 5. Multiple labels in same scope, multiple gotos
do
  local path = ""
  goto step2
  ::step1::
  path = path .. "1"
  goto done2
  ::step2::
  path = path .. "2"
  goto step1
  ::done2::
  ok(path == "21", "multiple labels: path is '21'")
end

-- 6. goto inside nested block jumps to outer label
do
  local fired = false
  for i = 1, 3 do
    for j = 1, 3 do
      if i == 2 and j == 2 then
        fired = true
        goto break_outer
      end
    end
  end
  ::break_outer::
  ok(fired, "goto breaks out of nested loops")
end

-- 7. goto skips a local variable declaration
do
  local result = 0
  goto after_decl
  -- local y = 99  -- would be a scope error; goto can only skip where no locals start
  ::after_decl::
  result = 1
  ok(result == 1, "goto after_decl reaches code correctly")
end

-- 8. continue idiom accumulates values correctly
do
  local acc = 0
  for i = 1, 20 do
    if i % 3 ~= 0 then goto cont end
    acc = acc + i
    ::cont::
  end
  -- multiples of 3 from 1..20: 3+6+9+12+15+18 = 63
  ok(acc == 63, "continue idiom sum of multiples of 3 up to 20")
end

if fails == 0 then print("[+] PASS test_goto") os.exit(0) else os.exit(1) end
