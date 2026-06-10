-- AOT differential: if/elseif/else, while, repeat-until, and nested control flow.
for i = 1, 6 do
  if i == 1 then print("one")
  elseif i == 2 then print("two")
  elseif i < 5 then print("few:" .. i)
  else print("many:" .. i) end
end

-- while loop
local i = 0
local sum = 0
while i < 10 do
  sum = sum + i
  i = i + 1
end
print("while sum", sum)

-- repeat-until (body runs at least once)
local n = 0
repeat
  n = n + 3
until n >= 12
print("repeat n", n)

-- nested loops + early structure
local total = 0
for a = 1, 3 do
  for b = 1, 3 do
    if a == b then total = total + 10 else total = total + 1 end
  end
end
print("nested total", total)

-- a loop that's a zero-trip while
local k = 100
while k < 50 do print("must not print") k = k + 1 end
print("done")
