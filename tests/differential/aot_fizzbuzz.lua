-- Combined arith + control-flow differential (Plan 1): for-loop, if/elseif/else,
-- modulo, full arithmetic, bitwise, comparisons, concat, length, unary.
-- Compiled by aotc and byte-diffed against clua-interp.exe -i.
for i = 1, 15 do
  if i % 15 == 0 then
    print("FizzBuzz")
  elseif i % 3 == 0 then
    print("Fizz")
  elseif i % 5 == 0 then
    print("Buzz")
  else
    print(i .. "!")
  end
end
local a, b = 7, 2
print(a + b, a - b, a * b, a // b, a % b, a ^ b)
print(a & b, a | b, a ~ b, a << b, a >> b, ~a)
print(1 < 2, 2 <= 2, 3 == 3.0, "x" ~= "y", -a, #"hello")
