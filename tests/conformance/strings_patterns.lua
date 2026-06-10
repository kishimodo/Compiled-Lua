-- strings_patterns.lua : find/match/gmatch/gsub/byte/char/rep/sub + pattern edges.
-- Deterministic; JIT and -i must agree byte-for-byte.

local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(table.concat(parts, "\t"))
end

-- find: plain and pattern, with captures and positions
show(string.find("hello world", "world"))            -- 7 11
show(string.find("hello world", "o", 6))             -- 8 8
show(string.find("a.b.c", ".", 1, true))             -- plain: 2 2
show(string.find("key=value", "(%w+)=(%w+)"))        -- 1 9 key value
show(string.find("abc", "x"))                        -- nil

-- match: single and multiple captures, anchors
show(string.match("2026-06-07", "(%d+)-(%d+)-(%d+)"))
show(string.match("  trim  ", "^%s*(.-)%s*$"))       -- "trim"
show(string.match("hello", "^h"))                    -- h
show(string.match("hello", "l+"))                    -- ll
show(string.match("abc123", "%a+"), string.match("abc123", "%d+"))
show(string.match("", "()"))                          -- position capture: 1

-- gmatch: iterate words, then key=value pairs
do
  local words = {}
  for w in string.gmatch("the quick brown fox", "%a+") do words[#words+1] = w end
  show(table.concat(words, "|"))
end
do
  local out = {}
  for k, v in string.gmatch("a=1, b=2, c=3", "(%w+)=(%w+)") do
    out[#out+1] = k .. ":" .. v
  end
  show(table.concat(out, " "))
end

-- gsub: count, replacement string with %1, function replacement, table replacement
show(string.gsub("hello world", "o", "0"))           -- hell0 w0rld 2
show(string.gsub("hello", "l", "L", 1))              -- heLlo 1
show(string.gsub("2026-06-07", "(%d+)-(%d+)", "%2/%1"))
show((string.gsub("abc", "%a", function(c) return c:upper() end)))
show((string.gsub("$name is $age", "%$(%w+)", {name = "Sam", age = "9"})))
show(string.gsub("aaa", "", "-"))                    -- empty pattern: insert between

-- %f frontier pattern and balanced match %b
show(string.match("THE (quick) fox", "%b()"))        -- (quick)
show((string.gsub("hello world from here", "%f[%a]%a", string.upper)))

-- character classes and sets, magic-char escaping
show(string.match("a1b2c3", "[%a%d]+"))
show(string.match("file.tar.gz", "%.([^.]+)$"))      -- gz
show(string.gsub("1+2=3", "%+", " plus "))

-- byte / char round trips
show(string.byte("A"), string.byte("ABC", 2), string.byte("ABC", 1, 3))
show(string.char(72, 101, 108, 108, 111))            -- Hello
show(string.byte("Z", -1))                           -- negative index from end

-- rep with and without separator, sub with negative indices
show(string.rep("ab", 3), string.rep("x", 0), string.rep("-", 3, "+"))
show(string.sub("hello", 2, 4), string.sub("hello", -3), string.sub("hello", -3, -2))
show(string.sub("hello", 0), string.sub("hello", 10))

-- upper / lower / len / reverse
show(("MixedCase"):upper(), ("MixedCase"):lower(), ("abc"):reverse(), ("hello"):len())

-- %d in patterns vs captures, and anchoring with $
show(string.match("price: 42 dollars", "(%d+)"))
show(string.find("end.", "%.$"))                     -- 4 4
