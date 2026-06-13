-- table.move : overlapping ranges, growth, cross-table, edge cases. Lua 5.4
-- guarantees correct behavior even when source and destination ranges overlap.

local function dump(t, n)
  local p = {}
  for i = 1, n do p[i] = tostring(t[i]) end
  print(table.concat(p, ","))
end

-- shift right (overlap, dest > src): must not clobber unread source elements
do
  local a = { 1, 2, 3, 4, 5 }
  table.move(a, 1, 5, 2)          -- a[2..6] = a[1..5]
  dump(a, 6)                       -- 1,1,2,3,4,5
end

-- shift left (overlap, dest < src)
do
  local a = { 1, 2, 3, 4, 5 }
  table.move(a, 2, 5, 1)          -- a[1..4] = a[2..5]
  dump(a, 5)                       -- 2,3,4,5,5
end

-- copy to a different table
do
  local src = { 10, 20, 30 }
  local dst = { 0, 0, 0, 0, 0 }
  table.move(src, 1, 3, 3, dst)   -- dst[3..5] = src[1..3]
  dump(dst, 5)                     -- 0,0,10,20,30
end

-- identity move (dest == src position) is a no-op
do
  local a = { 7, 8, 9 }
  table.move(a, 1, 3, 1)
  dump(a, 3)                       -- 7,8,9
end

-- empty range (f > e) does nothing and returns the destination table
do
  local a = { 1, 2, 3 }
  local r = table.move(a, 3, 1, 1) -- f=3 > e=1 -> no-op
  print(r == a, a[1], a[2], a[3])  -- true 1 2 3
end

-- move can carry nils (holes) faithfully
do
  local a = { 1, nil, 3, nil, 5 }
  local b = {}
  table.move(a, 1, 5, 1, b)
  print(b[1], tostring(b[2]), b[3], tostring(b[4]), b[5])  -- 1 nil 3 nil 5
end

-- return value is the destination table
do
  local a, b = { 1, 2 }, { 0, 0, 0 }
  print(table.move(a, 1, 2, 2, b) == b)  -- true
end

print("[+] PASS table_move")
