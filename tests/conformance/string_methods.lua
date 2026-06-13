-- String method-call syntax: s:method(...) dispatches through the string
-- metatable (__index = string). A very common real-world pattern that also
-- exercises OP_SELF + the string library end to end.

local function show(...)
  local p = {}
  for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
  print(table.concat(p, "\t"))
end

local s = "Hello, World"

-- the metatable wiring itself
show(getmetatable(s) ~= nil, getmetatable(s).__index == string)

-- method calls vs the function-call equivalents (must agree)
show(s:len(), #s, string.len(s))
show(s:upper(), s:lower())
show(s:sub(1, 5), s:sub(-5), s:sub(8))
show(s:byte(1), s:byte(-1), s:byte(1, 3))
show(("abc"):rep(3), ("ab"):rep(3, "-"))
show(s:find("World"), s:find("o", 6))
show(s:gsub("o", "0"))
show(s:gsub("l", "L", 1))
show(("  trim  "):gsub("^%s*(.-)%s*$", "%1"))
show(s:match("(%w+), (%w+)"))
show(("a,b,c,d"):gmatch("%w+")())          -- first token

-- chaining methods
show(("MixedCase"):lower():upper():sub(1, 3))

-- method call on a string literal in parentheses
show(("%d-%d"):format(3, 4))

-- a numeric literal needs parens to call a method; via a variable it is fine
do
  local n = "42"
  show(n:rep(2), n:reverse())
end

-- iterate words with gmatch in a for-loop, count + concat (deterministic)
do
  local words, n = {}, 0
  for w in ("the quick brown fox"):gmatch("%a+") do n = n + 1; words[n] = w:upper() end
  print(n, table.concat(words, " "))
end

print("[+] PASS string_methods")
