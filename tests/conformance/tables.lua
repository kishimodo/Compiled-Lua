-- tables.lua : table.sort (custom comparators), move, pack/unpack, insert/remove,
-- concat, plus length operator edge behavior. Deterministic; JIT and -i must agree.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- sort: default ascending
do
  local t = {3, 1, 4, 1, 5, 9, 2, 6}
  table.sort(t)
  show(table.concat(t, ","))
end

-- sort: descending custom comparator
do
  local t = {3, 1, 4, 1, 5, 9, 2, 6}
  table.sort(t, function(a, b) return a > b end)
  show(table.concat(t, ","))
end

-- sort: by string length then lexicographically (stable-ish total order)
do
  local t = {"banana", "kiwi", "fig", "apple", "date"}
  table.sort(t, function(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
  end)
  show(table.concat(t, ","))
end

-- sort: records by a field
do
  local people = {
    {name = "Carol", age = 30}, {name = "Alice", age = 25}, {name = "Bob", age = 25},
  }
  table.sort(people, function(a, b)
    if a.age ~= b.age then return a.age < b.age end
    return a.name < b.name
  end)
  local out = {}
  for _, p in ipairs(people) do out[#out+1] = p.name .. "/" .. p.age end
  show(table.concat(out, " "))
end

-- sort a larger array, verify sortedness
do
  local t = {}
  for i = 1, 200 do t[i] = (i * 7919) % 1000 end
  table.sort(t)
  local ok = true
  for i = 2, #t do if t[i-1] > t[i] then ok = false end end
  show("sorted-200", ok, t[1], t[#t])
end

-- insert: at end and at position
do
  local t = {1, 2, 3}
  table.insert(t, 4)
  table.insert(t, 1, 0)
  show(table.concat(t, ","))                          -- 0,1,2,3,4
end

-- remove: from end, from position, return value
do
  local t = {10, 20, 30, 40}
  local last = table.remove(t)
  local mid = table.remove(t, 2)
  show(last, mid, table.concat(t, ","))               -- 40 20 10,30
end

-- move: shift within array, overlapping ranges, cross-table
do
  local t = {1, 2, 3, 4, 5}
  table.move(t, 2, 4, 1)                               -- copy [2..4] to start
  show(table.concat(t, ","))                           -- 2,3,4,4,5
  local dst = {}
  table.move({7, 8, 9}, 1, 3, 1, dst)
  show(table.concat(dst, ","))                         -- 7,8,9
end

-- pack / unpack incl. the .n field and explicit ranges
do
  local p = table.pack(1, nil, 3, nil)
  show(p.n, p[1], p[3])                                -- 4 1 3
  show(table.unpack({10, 20, 30}))                     -- 10 20 30
  show(table.unpack({10, 20, 30, 40}, 2, 3))           -- 20 30
end

-- concat with separator and i,j range
show(table.concat({"a", "b", "c", "d"}, "-", 2, 3))    -- b-c
show(table.concat({1, 2, 3}, "", 1, 0))                -- empty (i>j)

-- length operator on a sequence
do
  local t = {1, 2, 3, 4, 5}
  show(#t)
  t[5] = nil
  show(#t)                                             -- 4 (border)
end
