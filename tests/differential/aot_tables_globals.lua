-- AOT differential: global writes compile to SETTABUP on _ENV (upvalue 0).
-- Exercises both constant and register value operands, write-then-read, and
-- arithmetic feeding a global write.

g = 99                 -- SETTABUP _ENV "g" with a constant value (Ck < 0)
print(g)

count = 0
for i = 1, 10 do count = count + i end   -- repeated global read+write via _ENV
print("count", count)

name = "world"
greeting = "hi " .. name
print(greeting)

-- a global holding a table, mutated through field/index ops
data = {}
data.n = 3
data[1] = 100
print("data", data.n, data[1])
