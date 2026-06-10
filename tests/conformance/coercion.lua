-- coercion.lua : string<->number coercion rules in Lua 5.4.
--  * arithmetic on numeric strings coerces to number (result is a number);
--  * concatenation coerces numbers to strings;
--  * tonumber with bases; tostring of numbers;
--  * comparison does NOT coerce (number vs string compare errors -> pcall'd).
-- Deterministic; JIT and -i must agree byte-for-byte.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- arithmetic coerces numeric strings; in 5.4 the result type depends on the
-- string's form (integer-looking -> integer, else float)
show("10" + 5, "10" * 2, "3.5" + 0, "0x10" + 0)        -- 15 20 3.5 16
show(math.type("10" + 0), math.type("10.0" + 0), math.type("0x1p4" + 0))
show("100" - "40", "2" ^ "10")                          -- 60 1024.0 (^ always float)
show(" 42 " + 0)                                        -- surrounding spaces allowed: 42

-- concatenation coerces numbers (and integer vs float spelling preserved)
show(1 .. 2, 1.5 .. "x", "n=" .. 42, "f=" .. 3.0)       -- 12 1.5x n=42 f=3.0
show(true and ("a" .. 1 .. "b"))                        -- a1b
show(10 // 3 .. "!", (1/0) .. "")                       -- 3! inf

-- tonumber: plain, with base, failure cases
show(tonumber("42"), tonumber("3.14"), tonumber("  7  "))
show(tonumber("0xFF"), tonumber("1e3"), tonumber("0x1p8"))
show(tonumber("ff", 16), tonumber("777", 8), tonumber("101", 2))
show(tonumber("z", 36), tonumber("10", 2))             -- 35 2
show(tonumber("hello"), tonumber(""), tonumber("12abc"))  -- nil nil nil
show(tonumber("  "), tonumber("0x"), tonumber("."))        -- nil nil nil
show(math.type(tonumber("5")), math.type(tonumber("5.0")))

-- tonumber on a number returns it unchanged (preserving subtype)
show(tonumber(7), tonumber(7.5), math.type(tonumber(7)))

-- tostring spelling of numbers used in coercion
show(tostring(0), tostring(-0.0), tostring(1e20), tostring(2^63))

-- comparison does NOT coerce: "10" < 9 is an error -> pcall captures it
show(pcall(function() return "10" < 9 end))             -- false ...compare
show(pcall(function() return 1 < "2" end))              -- false ...compare
-- but == between number and string is just false (no coercion, no error)
show(10 == "10", "10" == 10, 0 == "")                   -- false false false

-- numeric for with string bounds coerces them to numbers
do
  local acc = {}
  for i = "1", "5", "2" do acc[#acc+1] = i end          -- 1,3,5 (step "2")
  show(table.concat(acc, ","))
end

-- length operator coerces nothing but works on strings directly
show(#"hello", #"")                                      -- 5 0

-- a numeric string used as a table key vs the number key (distinct keys!)
do
  local t = {}
  t[1] = "int-key"
  t["1"] = "str-key"
  show(t[1], t["1"], t[1] == t["1"])                     -- int-key str-key false
end

-- integer vs float key normalization: t[2.0] and t[2] are the SAME key
do
  local t = {}
  t[2] = "via-int"
  show(t[2.0])                                            -- via-int (2.0 -> 2)
  t[3.0] = "via-float"
  show(t[3])                                              -- via-float
end
