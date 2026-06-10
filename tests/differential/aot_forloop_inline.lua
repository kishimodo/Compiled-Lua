-- M1 inline integer FORLOOP fast path (runtime-checked on the step tag; float
-- loops fall to Rt_ForLoop). Mirrors lvm.c's integer OP_FORLOOP. Stresses steps,
-- direction, large counts, nesting, break, and the float path. Compiled by aotc
-- and byte-diffed vs luavm.exe -i.

-- basic ascending / unit step
local s = 0
for i = 1, 10 do s = s + i end
print(s)                                  -- 55

-- step > 1, exact and inexact end
local a = {}
for i = 1, 10, 3 do a[#a + 1] = i end
print(table.concat(a, ","))               -- 1,4,7,10
local b = {}
for i = 1, 9, 2 do b[#b + 1] = i end
print(table.concat(b, ","))               -- 1,3,5,7,9

-- descending (negative step)
local d = {}
for i = 5, 1, -1 do d[#d + 1] = i end
print(table.concat(d, ","))               -- 5,4,3,2,1
for i = 10, 1, -3 do io.write(i, " ") end
print()                                    -- 10 7 4 1

-- loops that do not execute
local never = 0
for i = 5, 1 do never = never + 1 end      -- empty (ascending, lo>hi)
for i = 1, 5, -1 do never = never + 1 end  -- empty (descending, lo<hi)
print("never =", never)                    -- never = 0

-- single iteration
for i = 7, 7 do print("single", i) end     -- single 7

-- nested loops (register reuse / multiple FORLOOPs)
local sum = 0
for i = 1, 4 do
  for j = 1, 4 do
    sum = sum + i * j
  end
end
print("nested", sum)                       -- nested 100

-- break out of an integer loop
local found
for i = 1, 100 do if i * i > 50 then found = i break end end
print("break", found)                      -- break 8

-- large count (exceeds 32 bits of iterations? no -- but large bound) + accumulator
local acc = 0
for i = 1, 1000000 do acc = acc + 1 end
print("acc", acc)                          -- acc 1000000

-- counting near integer limits (wrapping step semantics)
local cnt = 0
for i = math.maxinteger - 2, math.maxinteger do cnt = cnt + 1 end
print("near max", cnt)                     -- near max 3

-- FLOAT for-loop must use the helper path and match exactly
local fs = 0.0
for x = 1.0, 3.0, 0.5 do fs = fs + x end
print("float", fs)                         -- float 10.0  (1+1.5+2+2.5+3)
for x = 1, 3, 0.5 do io.write(x, " ") end  -- float loop (step is float); io.write %.14g
print()                                    -- 1 1.5 2 2.5 3
