-- JIT-vs-interpreter equivalence for numeric-for loop-variable mutation.
-- Lua 5.4 makes the loop variable a fresh local each iteration, so a body that
-- reassigns it must NOT affect the iteration sequence. The JIT integer FORLOOP
-- used to thread the mutation back in (it advanced the VISIBLE control variable
-- R[A+3] instead of the hidden internal index R[A]), so e.g. `for i=1,5 do
-- t[]=i; i=i+100 end` produced 1,102,203,304,405 under the JIT vs 1,2,3,4,5 in
-- the interpreter. Deterministic prints; the runner diffs JIT stdout against -i.
local function show(label, t) print(label, table.concat(t, ",")) end

do local t = {} for i = 1, 5 do t[#t+1] = i; i = i + 100 end show("up1", t) end
do local t = {} for i = 0, 20, 4 do t[#t+1] = i; i = i * 2 end show("up4", t) end
do local t = {} for i = 10, 1, -2 do t[#t+1] = i; i = i - 99 end show("down", t) end
do local t = {} for i = 1.0, 3.0, 0.5 do t[#t+1] = tostring(i); i = i + 9 end show("flt", t) end
do
  local t = {}
  for i = 1, 3 do
    for j = 1, 2 do t[#t+1] = i * 10 + j; j = j + 50 end
    i = i + 50
  end
  show("nest", t)
end
-- mutation must not change the trip count either
local sum = 0
for i = 1, 100 do sum = sum + i; i = 0 end
print("sum", sum)
