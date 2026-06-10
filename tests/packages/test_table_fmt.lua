-- tests/packages/test_table_fmt.lua : table_fmt rendering round-trips.
-- Asserts structural facts (alignment, header band, row count, separators)
-- against hand-computed reference output -- never the code's own echo.
local ok_req, table_fmt = pcall(require, "table_fmt")
if not ok_req then print("[~] SKIP test_table_fmt") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_table_fmt: " .. tostring(m)) end end

-- helper: split rendered output into lines
local function lines(s)
  local t = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t+1] = line end
  return t
end

-- ---- ascii style: full structural check against hand-computed widths ----
-- col1 width = max("H1"=2,"a"=1,"ccc"=3)=3 ; col2 width = max("H2"=2,"bb"=2,"d"=1)=2
-- pad=1 default. Glyphs: h="-", v="|", corners/junctions="+".
do
  local s = table_fmt.format({ { "a", "bb" }, { "ccc", "d" } }, { headers = { "H1", "H2" } })
  local L = lines(s)
  -- top, header, mid, row1, row2, bottom = 6 lines
  ok(#L == 6, "ascii: header table has top+header+mid+2rows+bottom = 6 lines, got " .. #L)
  ok(L[1] == "+-----+----+", "ascii: top rule, got [" .. tostring(L[1]) .. "]")
  ok(L[2] == "| H1  | H2 |", "ascii: header row, got [" .. tostring(L[2]) .. "]")
  ok(L[3] == "+-----+----+", "ascii: mid rule, got [" .. tostring(L[3]) .. "]")
  ok(L[4] == "| a   | bb |", "ascii: row 1 left-padded, got [" .. tostring(L[4]) .. "]")
  ok(L[5] == "| ccc | d  |", "ascii: row 2, got [" .. tostring(L[5]) .. "]")
  ok(L[6] == "+-----+----+", "ascii: bottom rule, got [" .. tostring(L[6]) .. "]")
end

-- ---- columns truly align: every body line same length ----
do
  local s = table_fmt.format({ { "x", "yyyy" }, { "zzzz", "w" } }, { headers = { "A", "B" } })
  local L = lines(s)
  local w = #L[1]
  for i = 2, #L do ok(#L[i] == w, "ascii align: line " .. i .. " width " .. #L[i] .. " != " .. w) end
end

-- ---- right / center alignment ----
do
  -- single column, values width up to 3 ("ccc"); header "H"
  local s = table_fmt.format({ { "a" }, { "ccc" } }, { headers = { "H" }, align = { "right" } })
  local L = lines(s)
  -- width=3, pad=1 -> "| " + pad_to("a",3,right) "  a" + " |"
  ok(L[4] == "|   a |", "right align pads on the left, got [" .. tostring(L[4]) .. "]")
  ok(L[5] == "| ccc |", "right align full cell, got [" .. tostring(L[5]) .. "]")
end
do
  local s = table_fmt.format({ { "x" } }, { headers = { "HHHHH" }, align = { "center" } })
  local L = lines(s)
  -- width=5 ("HHHHH"); center "x": diff=4 -> 2 left, 2 right -> "  x  "
  ok(L[4] == "|   x   |", "center align splits padding, got [" .. tostring(L[4]) .. "]")
end

-- ---- markdown style: header + separator with colon cues ----
do
  local s = table_fmt.format({ { "1", "2" } }, { headers = { "A", "B" }, style = "markdown" })
  local L = lines(s)
  ok(#L == 3, "markdown: header+sep+1row = 3 lines, got " .. #L)
  -- widths: A col max("A","1")=1 ; B col max("B","2")=1. pad=1 -> dashes = 1+2 = 3
  ok(L[1] == "| A | B |", "markdown header, got [" .. tostring(L[1]) .. "]")
  ok(L[2] == "|---|---|", "markdown default separator (no align), got [" .. tostring(L[2]) .. "]")
  ok(L[3] == "| 1 | 2 |", "markdown body row, got [" .. tostring(L[3]) .. "]")
end
do
  -- alignment colon cues in markdown sep
  local s = table_fmt.format({ { "1", "2", "3" } },
    { headers = { "A", "B", "C" }, style = "markdown", align = { "left", "right", "center" } })
  local sep = lines(s)[2]
  -- each seg starts as 3 dashes "---"; left -> ":--", right -> "--:", center -> ":-:"
  ok(sep == "|:--|--:|:-:|", "markdown colon cues per alignment, got [" .. tostring(sep) .. "]")
end

-- ---- csv style: comma join + quoting of embedded commas/quotes/newlines ----
do
  local s = table_fmt.format({ { "a", "b,c" }, { 'he said "hi"', "x" } },
    { headers = { "H1", "H2" }, style = "csv" })
  local L = lines(s)
  ok(#L == 3, "csv: header + 2 rows = 3 lines, got " .. #L)
  ok(L[1] == "H1,H2", "csv header, got [" .. tostring(L[1]) .. "]")
  ok(L[2] == 'a,"b,c"', "csv quotes field containing comma, got [" .. tostring(L[2]) .. "]")
  ok(L[3] == '"he said ""hi""",x', "csv doubles embedded quotes, got [" .. tostring(L[3]) .. "]")
end

-- ---- tsv style: tab join, embedded tabs/newlines collapsed to spaces ----
do
  local s = table_fmt.format({ { "a\tb", "c" } }, { style = "tsv" })
  ok(s == "a b\tc", "tsv tab-joins and replaces embedded tab with space, got [" .. tostring(s) .. "]")
end

-- ---- array-of-maps: headers determine column order ----
do
  local s = table_fmt.format({ { name = "ann", age = 30 }, { name = "bob", age = 7 } },
    { headers = { "name", "age" }, style = "markdown" })
  local L = lines(s)
  ok(L[1] == "| name | age |", "map rows ordered by headers, got [" .. tostring(L[1]) .. "]")
  ok(L[3]:find("ann", 1, true) ~= nil and L[3]:find("30", 1, true) ~= nil, "map row 1 has its values")
  ok(L[4]:find("bob", 1, true) ~= nil and L[4]:find("7", 1, true) ~= nil, "map row 2 has its values")
end

-- ---- array-of-strings: single "value" column ----
do
  local s = table_fmt.format({ "alpha", "beta" }, { style = "markdown" })
  local L = lines(s)
  ok(L[1] == "| value |", "string rows get a synthetic 'value' header, got [" .. tostring(L[1]) .. "]")
  ok(L[3] == "| alpha |", "string row 1, got [" .. tostring(L[3]) .. "]")
  ok(L[4] == "| beta  |", "string row 2, got [" .. tostring(L[4]) .. "]")
end

-- ---- truncation with ellipsis ----
do
  local s = table_fmt.format({ { "abcdefgh" } }, { headers = { "H" }, max_width = 5, truncate = true })
  local L = lines(s)
  -- truncate_cell("abcdefgh",5,"...") -> sub(1,5-3).."..." = "ab..."  (width 5)
  ok(L[4] == "| ab... |", "truncate to max_width with default ellipsis, got [" .. tostring(L[4]) .. "]")
end

-- ---- wrap soft-wraps on spaces into multiple display rows ----
do
  local s = table_fmt.format({ { "one two three" } }, { headers = { "H" }, max_width = 4, wrap = true })
  local L = lines(s)
  -- words wrap at width 4: "one","two","three"(>4 -> hard split "thre","e")
  -- => 4 body lines. structure: top,header,mid,4 body,bottom = 8
  ok(#L == 8, "wrap expands one row into 4 display lines (8 total), got " .. #L)
  ok(L[4]:find("one", 1, true) ~= nil, "wrap line keeps first word")
end

-- ---- style() accessor returns the glyph table; falls back to ascii ----
do
  ok(table_fmt.style("box").v == "\u{2502}", "style('box') returns box glyphs")
  ok(table_fmt.style("nope") == table_fmt.styles.ascii, "unknown style falls back to ascii")
end

-- ---- zero data rows: header band renders, no body rows ----
-- (format({}) is a degenerate zero-column frame; the meaningful contract is
-- that headers with no rows yield a header+separator and no data lines.)
do
  local s = table_fmt.format({}, { headers = { "Col" }, style = "markdown" })
  local L = lines(s)
  ok(#L == 2, "markdown with headers but no rows = header+sep only, got " .. #L)
  ok(L[1] == "| Col |", "empty-body markdown header, got [" .. tostring(L[1]) .. "]")
  ok(L[2] == "|-----|", "empty-body markdown separator (5 dashes), got [" .. tostring(L[2]) .. "]")
end

if fails == 0 then print("[+] PASS test_table_fmt") os.exit(0) else os.exit(1) end
