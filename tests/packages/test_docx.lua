-- tests/packages/test_docx.lua : docx writer -> reader round-trip.
-- Runner bundles docx + zip + xml + zlib, compiles, runs under JIT and -i,
-- byte-comparing stdout. Output must be deterministic.
local ok_req, docx = pcall(require, "docx")
if not ok_req then print("[~] SKIP test_docx (" .. tostring(docx) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_docx: " .. tostring(m)) end end

local path = os.getenv("TEMP") .. "/clua_test_docx_rt.docx"

-- ===== Build a document ==================================================
local w = docx.create()
w:set_metadata({ title = "My Report", author = "Ada", subject = "Testing" })
w:add_paragraph("Hello world")
w:add_paragraph("Bold line", { bold = true })
w:add_page_break()
w:add_paragraph("After break")
w:add_table({
    { "Name", "Score" },
    { "alice", "30" },
    { "bob", "25" },
})
w:save(path)

-- ===== Read it back ======================================================
local doc = docx.open(path)

-- text(): paragraphs joined by newlines. The table cells become their own
-- paragraphs inside the table, so just assert our standalone paragraph text
-- appears in order at the front.
local txt = doc:text()
ok(txt:find("Hello world", 1, true) ~= nil, "text contains 'Hello world'")
ok(txt:find("Bold line", 1, true) ~= nil,   "text contains 'Bold line'")
ok(txt:find("After break", 1, true) ~= nil,  "text contains 'After break'")
-- Order: Hello world precedes After break
local i_hello = txt:find("Hello world", 1, true)
local i_after = txt:find("After break", 1, true)
ok(i_hello and i_after and i_hello < i_after, "paragraph order preserved")

-- paragraphs(): iterate and collect run text + bold flag deterministically
local paras = {}
for p in doc:paragraphs() do
    local t = {}
    for _, run in ipairs(p.runs) do t[#t + 1] = run.text end
    paras[#paras + 1] = { text = table.concat(t), runs = p.runs }
end
ok(#paras >= 4, "at least 4 paragraphs present (3 text + page break)")
ok(paras[1].text == "Hello world", "first paragraph text exact")
ok(paras[2].text == "Bold line",   "second paragraph text exact")
ok(paras[2].runs[1].bold == true,  "bold run flag round-trips")
ok(paras[1].runs[1].bold == nil,   "non-bold run has no bold flag")

-- tables(): one table, 3 rows x 2 cols
local tabs = doc:tables()
ok(#tabs == 1, "exactly one table")
ok(#tabs[1].rows == 3, "table has 3 rows")
ok(#tabs[1].rows[1] == 2, "table row has 2 cells")
ok(tabs[1].rows[1][1] == "Name", "table header cell [1][1]=Name")
ok(tabs[1].rows[1][2] == "Score", "table header cell [1][2]=Score")
ok(tabs[1].rows[2][1] == "alice", "table cell [2][1]=alice")
ok(tabs[1].rows[3][2] == "25",   "table cell [3][2]=25")

-- metadata(): core props round-trip
local meta = doc:metadata()
ok(meta.title == "My Report", "metadata title round-trips")
ok(meta.author == "Ada",      "metadata author round-trips")
ok(meta.subject == "Testing", "metadata subject round-trips")

-- images(): none added -> empty
ok(#doc:images() == 0, "no images in this document")

os.remove(path)
if fails == 0 then print("[+] PASS test_docx") os.exit(0) else os.exit(1) end
