-- varargs_select.lua : ... handling + select (count and from-index), nil holes,
-- table.pack/unpack interplay, forwarding. Deterministic; JIT and -i must agree.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- select("#", ...) counts args including trailing nils and holes
local function count(...) return select("#", ...) end
show(count(), count(1), count(1, 2, 3), count(nil), count(nil, nil), count(1, nil, 3))

-- select(n, ...) returns args from position n
local function from(n, ...) return select(n, ...) end
show(from(1, "a", "b", "c"))               -- a b c
show(from(2, "a", "b", "c"))               -- b c
show(from(3, "a", "b", "c"))               -- c
show(from(-1, "a", "b", "c"))              -- c (negative: from end)

-- varargs in table constructor: trailing ... expands, mid ... truncates to 1
local function pack_tail(...) return {...} end
local function pack_mid(...) return {..., "X"} end
do
  local t = pack_tail(1, 2, 3)
  show(#t, t[1], t[2], t[3])
  local m = pack_mid(1, 2, 3)
  show(#m, m[1], m[2])                     -- 2 1 X (... truncated to first)
end

-- forwarding varargs through a function
local function wrapper(...) return show("fwd", ...) end
wrapper(10, 20, 30)

-- nil holes preserved by table.pack via .n
local function via_pack(...) return table.pack(...) end
do
  local p = via_pack(1, nil, nil, 4)
  show(p.n, p[1], p[4])                    -- 4 1 4
end

-- multiple returns adjusted: only last call in a list expands
local function multi() return 1, 2, 3 end
show(multi())                              -- 1 2 3
show(multi(), 99)                          -- 1 99 (multi() truncated to first)
show(99, multi())                          -- 99 1 2 3 (last position expands)
do
  local a, b, c, d = multi(), multi()
  show(a, b, c, d)                         -- 1 1 2 3
end

-- select with computed index
local function nth(i, ...) return (select(i, ...)) end
show(nth(2, "x", "y", "z"))               -- y

-- vararg arithmetic: sum
local function sum(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + select(i, ...) end
  return s
end
show(sum(), sum(1, 2, 3, 4, 5), sum(-10, 10))

-- mixing fixed params with ...
local function head_tail(first, ...)
  return first, select("#", ...), ...
end
show(head_tail("h", "a", "b"))            -- h 2 a b
show(head_tail("only"))                   -- only 0
