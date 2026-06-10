-- tests/packages/test_pdf_read.lua : pdf_read parser, fed by pdf_write output.
-- Runner bundles pdf_read (+ pdf_write, zlib) and compiles/runs under JIT and
-- -i, byte-comparing stdout. All assertions are deterministic.
local ok_req, pdf_read = pcall(require, "pdf_read")
if not ok_req then print("[~] SKIP test_pdf_read (" .. tostring(pdf_read) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_pdf_read: " .. tostring(m)) end end

-- Generate a deterministic PDF with the writer (its content/structure is what
-- we parse). pdf_write must be available for this test to be meaningful.
local ok_w, pdf_write = pcall(require, "pdf_write")
if not ok_w then print("[~] SKIP test_pdf_read (pdf_write unavailable: " .. tostring(pdf_write) .. ")") os.exit(0) end

local d = pdf_write.doc({ title = "Round Trip", author = "Reader Test", page_size = "letter" })
local p1 = d:add_page()
p1:text("Hello PDF World", 72, 700, { size = 14 })
p1:link({ 72, 580, 100, 20 }, "https://example.com/x")
local p2 = d:add_page({ width = 200, height = 300 })
p2:text("Second Page Text", 20, 280)
local bytes = d:to_bytes()

-- ===== open() from bytes (starts with %PDF) ==============================
local doc = pdf_read.open(bytes)
ok(doc ~= nil, "open() from bytes succeeds")

-- page_count
ok(doc:page_count() == 2, "page_count == 2")

-- metadata
local meta = doc:metadata()
ok(meta.title == "Round Trip",  "metadata title parsed")
ok(meta.author == "Reader Test","metadata author parsed")
ok(meta.producer == "LuaVM pdf_write", "metadata producer parsed")

-- catalog
local cat = doc:catalog()
ok(type(cat) == "table" and cat.Type == "Catalog", "catalog is /Type /Catalog")

-- page 1: size, rotation, text
local pg1 = doc:page(1)
ok(pg1 ~= nil, "page(1) resolves")
local sz1 = pg1:size()
ok(sz1.width == 612 and sz1.height == 792, "page 1 is 612x792")
ok(pg1:rotation() == 0, "page 1 rotation 0")
local t1 = pg1:text()
ok(t1:find("Hello PDF World", 1, true) ~= nil, "page 1 text extracts 'Hello PDF World'")

-- page 2: custom size + text
local pg2 = doc:page(2)
local sz2 = pg2:size()
ok(sz2.width == 200 and sz2.height == 300, "page 2 is 200x300")
ok(pg2:text():find("Second Page Text", 1, true) ~= nil, "page 2 text extracts")

-- page(out-of-range) -> nil
ok(doc:page(99) == nil, "page(99) returns nil")

-- doc:text() joins all pages
local all = doc:text()
ok(all:find("Hello PDF World", 1, true) ~= nil, "doc:text has page 1 text")
ok(all:find("Second Page Text", 1, true) ~= nil, "doc:text has page 2 text")

-- annotations: one Link with URI on page 1
local annots = doc:annotations()
ok(#annots == 1, "one annotation total")
ok(annots[1].subtype == "Link", "annotation subtype Link")
ok(annots[1].page == 1, "annotation on page 1")
ok(annots[1].uri == "https://example.com/x", "annotation URI parsed")
ok(type(annots[1].rect) == "table" and #annots[1].rect == 4, "annotation rect is 4-array")

-- forms: none in this PDF
ok(#doc:forms() == 0, "no AcroForm fields")

-- error path: non-PDF bytes
local bad = not pcall(function() pdf_read.open("this is not a pdf at all") end)
ok(bad, "open() rejects non-PDF input")

if fails == 0 then print("[+] PASS test_pdf_read") os.exit(0) else os.exit(1) end
