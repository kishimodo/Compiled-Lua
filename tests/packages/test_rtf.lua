-- tests/packages/test_rtf.lua : RTF parse / to_text / to_html / writer round-trips.
-- Deterministic: all inputs are fixed RTF strings or fixed writer calls; we never
-- print addresses or iterate hash order without sorting/aggregating.
local ok_req, rtf = pcall(require, "rtf")
if not ok_req then print("[~] SKIP test_rtf (" .. tostring(rtf) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_rtf: " .. tostring(m)) end end
-- xfail: assert CORRECT behavior; if it ever starts passing we get told to drop it.
local function xfail(cond, desc, bug)
  if cond then print(("[!] XPASS test_rtf: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
  else        print(("[x] XFAIL test_rtf: %s (known bug %s)"):format(desc, bug)) end
end

-- ===== parse: basic plain text =====
local doc = rtf.parse("{\\rtf1\\ansi Hello World}")
ok(type(doc) == "table",                       "parse returns a table")
ok(type(doc.paragraphs) == "table",            "doc has paragraphs")
ok(#doc.paragraphs == 1,                        "single paragraph from one run")
ok(doc.paragraphs[1].runs[1].text == "Hello World", "plain text extracted")
ok(doc.charset == "ansi",                       "ansi charset recorded")

-- ===== parse: bold / italic runs =====
local d2 = rtf.parse("{\\rtf1 normal {\\b bolded}{\\i italics}}")
local txt2 = rtf.to_text(d2)
ok(txt2:find("normal", 1, true) ~= nil,         "to_text keeps normal text")
ok(txt2:find("bolded", 1, true) ~= nil,         "to_text keeps bold text")
ok(txt2:find("italics", 1, true) ~= nil,        "to_text keeps italic text")
-- locate the bold run and confirm its flag
local found_bold, found_italic = false, false
for _, para in ipairs(d2.paragraphs) do
  for _, run in ipairs(para.runs) do
    if run.text == "bolded" then found_bold = run.bold end
    if run.text == "italics" then found_italic = run.italic end
  end
end
ok(found_bold == true,                          "bold run flagged bold=true")
ok(found_italic == true,                        "italic run flagged italic=true")

-- ===== parse: paragraph break =====
local d3 = rtf.parse("{\\rtf1 first\\par second}")
ok(#d3.paragraphs == 2,                         "\\par splits paragraphs")

-- ===== parse: escapes and control symbols =====
local d4 = rtf.parse("{\\rtf1 a\\{b\\}c\\\\d}")
ok(rtf.to_text(d4):find("a{b}c\\d", 1, true) ~= nil, "brace/backslash escapes decoded")

-- ===== parse: \'xx hex byte =====
local d5 = rtf.parse("{\\rtf1 X\\'41Y}")  -- 0x41 = 'A'
ok(rtf.to_text(d5):find("XAY", 1, true) ~= nil, "\\'41 decodes to 'A'")

-- ===== parse: unicode \u =====
local d6 = rtf.parse("{\\rtf1 \\u233?}")  -- U+00E9 = é = C3 A9
local t6 = rtf.to_text(d6)
ok(t6:byte(1) == 0xC3 and t6:byte(2) == 0xA9, "\\u233 -> UTF-8 C3 A9")

-- ===== parse: alignment =====
local d7 = rtf.parse("{\\rtf1\\qc centered\\par}")
ok(d7.paragraphs[1].alignment == "center",      "\\qc sets center alignment")

-- ===== parse: metadata info field =====
local d8 = rtf.parse("{\\rtf1{\\info{\\title My Title}{\\author Jane}}body}")
ok(d8.metadata.title == "My Title",             "info title extracted")
ok(d8.metadata.author == "Jane",                "info author extracted")

-- ===== parse: color table =====
-- colortbl: leading ';' = auto/default color, then red, then blue.
local d9 = rtf.parse("{\\rtf1{\\colortbl;\\red255\\green0\\blue0;\\red0\\green0\\blue255;}text}")
ok(d9.colors[1].r == 0 and d9.colors[1].g == 0 and d9.colors[1].b == 0, "color 1 = auto black")
-- Regression (RTF-COLORTBL-001): the leading ';' (auto/default colour) used to
-- be double-counted, shifting the first real colour (red) to colors[3]. Correct
-- RTF semantics put auto-black at colors[1] and red at colors[2].
ok(d9.colors[2].r == 255 and d9.colors[2].g == 0 and d9.colors[2].b == 0,
   "red is colors[2] (leading ';' not double-counted) (regression RTF-COLORTBL-001)")
-- The mis-indexing also broke \cfN lookups: \cf1 must resolve to red.
local html_cf = rtf.to_html("{\\rtf1{\\colortbl;\\red255\\green0\\blue0;}\\cf1 redword\\par}")
ok(html_cf:find("color:#ff0000", 1, true) ~= nil,
   "\\cf1 renders red via colortbl (regression RTF-COLORTBL-001)")
-- These hold regardless of the off-by-one (blue is the last committed colour):
ok(d9.colors[#d9.colors].b == 255,               "last colortbl entry is blue (b=255)")
ok(d9.colors[#d9.colors].r == 0,                 "last colortbl entry has r=0")

-- ===== to_html =====
local html = rtf.to_html("{\\rtf1 hi {\\b strong}\\par}")
ok(html:find("<!DOCTYPE html>", 1, true) ~= nil, "to_html has doctype")
ok(html:find("<b>strong</b>", 1, true) ~= nil,   "to_html wraps bold in <b>")
ok(html:find("&lt;", 1, true) == nil,            "no spurious escape in plain content")
-- escaping of literal '<' in body
local d_esc = rtf.parse("{\\rtf1 a<b>c}")
ok(rtf.to_html(d_esc):find("a&lt;b&gt;c", 1, true) ~= nil, "to_html escapes < and >")

-- ===== parse rejects non-RTF =====
local ok_err = pcall(rtf.parse, "not rtf at all")
ok(ok_err == false,                              "parse rejects input not starting with {\\rtf")

-- ===== writer round-trip: create -> to_string -> parse =====
local w = rtf.create()
w:add_paragraph("Plain line")
w:add_paragraph("Heading text", { bold = true })
w:add_bold("BoldSpan")
local s = w:to_string()
ok(s:sub(1, 5) == "{\\rtf",                      "writer output starts with {\\rtf")
ok(s:sub(-1) == "}",                             "writer output ends with }")
local rd = rtf.parse(s)
local round_text = rtf.to_text(rd)
ok(round_text:find("Plain line", 1, true) ~= nil, "round-trip keeps plain paragraph")
ok(round_text:find("Heading text", 1, true) ~= nil, "round-trip keeps second paragraph")
ok(round_text:find("BoldSpan", 1, true) ~= nil,  "round-trip keeps bold span text")

-- ===== writer: escape special chars =====
local w2 = rtf.create()
w2:add_paragraph("a{b}c\\d")
local rd2 = rtf.parse(w2:to_string())
ok(rtf.to_text(rd2):find("a{b}c\\d", 1, true) ~= nil, "writer escapes braces/backslash, reads back")

-- ===== writer: table =====
local w3 = rtf.create()
w3:add_table({ { "r1c1", "r1c2" }, { "r2c1", "r2c2" } })
local s3 = w3:to_string()
ok(s3:find("\\trowd", 1, true) ~= nil,           "add_table emits \\trowd")
ok(s3:find("r1c1", 1, true) ~= nil,              "add_table includes cell text")

if fails == 0 then print("[+] PASS test_rtf") os.exit(0) else os.exit(1) end
