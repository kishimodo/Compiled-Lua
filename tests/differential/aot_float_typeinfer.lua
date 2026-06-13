-- M1 float-arith elision: when both operands of reg-reg ADD/SUB/MUL are proven
-- float (lc_pass_local_typeinfer), codegen emits a bare SSE op with no tag-check
-- and no helper. Validates correctness incl. mixed int/float (checked path),
-- a captured float mutated to int through a closure (must NOT elide), //, and
-- nan/inf propagation. Compiled by aotc and byte-diffed vs clua-interp.exe -i.

local s, x, y = 0.0, 1.5, 2.0
for i = 1, 5 do s = s + x * y - x end
print(s, math.type(s))                 -- 7.5  float  (5 * (1.5*2.0 - 1.5))

local a, b = 3.5, 2.0
print(a + b, a - b, a * b)             -- 5.5  1.5  7.0
print((a * b) + (a - b))               -- 8.5  (chained reg-reg float)

local f = 7.0 // 2.0
print(f, math.type(f))                 -- 3.0  float

-- mixed int + float: not both-float and not both-int -> checked path, stays correct
local m = 5
print(m + 2.5, 2.5 * m, m - 0.5)       -- 7.5  12.5  4.5

-- captured float mutated to an integer through a nested closure -> the proof must
-- demote it (no float elision), matching the interpreter
for d = 1, 1 do
  local v = 4.0
  local function g() v = 10 end
  g()
  print(v + 1, math.type(v))           -- 11  integer
end

-- nan / inf / -0.0 through proven-float arith
local inf = 1.0 / 0.0
local nan = 0.0 / 0.0
local z = -0.0
print(inf + 1.0, -inf * 2.0, nan ~= nan, z + 0.0)   -- inf  -inf  true  0.0
