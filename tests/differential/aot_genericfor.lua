-- AOT differential: generic for-in loops (Plan 3 TFORPREP/TFORCALL/TFORLOOP)
-- over ipairs and pairs, including break, an empty table, and a nested loop.

-- ipairs: index*value accumulation
local t = {10, 20, 30, 40}
local s = 0
for i, v in ipairs(t) do s = s + i * v end
print(s)

-- pairs: sum the values (order-independent reduction, so stable across runs)
local m = {a = 1, b = 2, c = 3, d = 4}
local k = 0
for _, val in pairs(m) do k = k + val end
print(k)

-- generic-for with break
local found = -1
for i, v in ipairs({5, 15, 25, 35}) do
  if v > 20 then found = i break end
end
print(found)

-- empty table: body never runs
local cnt = 0
for _ in pairs({}) do cnt = cnt + 1 end
print(cnt)

-- nested generic-for (build a flattened product sum)
local rows = {{1, 2}, {3, 4}}
local acc = 0
for _, row in ipairs(rows) do
  for _, x in ipairs(row) do
    acc = acc + x
  end
end
print(acc)

-- pairs over a mixed-key table, counting entries
local mixed = {[1] = "a", x = "b", [2] = "c", y = "d"}
local n = 0
for _ in pairs(mixed) do n = n + 1 end
print(n)
