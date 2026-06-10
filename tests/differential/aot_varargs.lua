-- AOT differential: varargs consumption (Plan 3 OP_VARARG) via {...}, select,
-- and forwarding. Exercises VARARG in both fixed-count and MULTRET forms.

-- collect varargs into a table and reduce
local function sum(...)
  local s = 0
  for _, v in ipairs({...}) do s = s + v end
  return s
end
print(sum(), sum(1), sum(1, 2, 3, 4, 5))

-- select('#', ...): count of arguments
local function count(...) return select('#', ...) end
print(count(), count(1), count(1, 2, 3), count(nil, nil))

-- select(n, ...): tail of the argument list
local function third(...) return select(3, ...) end
print(third(10, 20, 30, 40, 50))

-- forward varargs to another vararg function (VARARG MULTRET -> call args)
local function wrap(...) return sum(...) end
print(wrap(2, 4, 6, 8))

-- mix fixed params with varargs
local function tagged(tag, ...)
  return tag, select('#', ...), sum(...)
end
print(tagged("nums", 1, 2, 3))

-- varargs into multiple assignment
local function first_two(...)
  local a, b = ...
  return a, b
end
print(first_two(100, 200, 300))
