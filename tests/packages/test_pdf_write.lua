-- tests/packages/test_pdf_write.lua : pdf_write generator structure checks.
-- Runner bundles pdf_write (+ zlib, soft) and compiles/runs under JIT and -i,
-- byte-comparing stdout. We assert structural invariants of the emitted PDF
-- bytes (deterministic) rather than the timestamp in the Info dict.
local ok_req, pdf = pcall(require, "pdf_write")
if not ok_req then print("[~] SKIP test_pdf_write (" .. tostring(pdf) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_pdf_write: " .. tostring(m)) end end

-- ===== Page size table ===================================================
ok(pdf.PAGE_SIZES.letter[1] == 612 and pdf.PAGE_SIZES.letter[2] == 792, "letter is 612x792")
ok(pdf.PAGE_SIZES.a4[1] == 595 and pdf.PAGE_SIZES.a4[2] == 842, "a4 is 595x842")

-- ===== Build a document, inspect to_bytes() ==============================
local d = pdf.doc({ title = "Hello PDF", author = "Tester", page_size = "letter" })
local p1 = d:add_page()
p1:text("Hello, World", 72, 700, { size = 14 })
p1:line(72, 690, 540, 690, { line_width = 1 })
p1:rect(72, 600, 100, 50, { fill = true, color = { 1, 0, 0 } })
p1:circle(300, 400, 40, { color = { 0, 0, 1 } })
p1:link({ 72, 580, 100, 20 }, "https://example.com")
local p2 = d:add_page({ width = 200, height = 300 })
p2:text("Page two", 20, 280)

local bytes = d:to_bytes()
ok(type(bytes) == "string" and #bytes > 0, "to_bytes returns non-empty string")

-- Header + EOF
ok(bytes:sub(1, 8) == "%PDF-1.7", "starts with %PDF-1.7 header")
ok(bytes:find("%%%%EOF") ~= nil, "ends-region contains %%EOF marker")

-- Structural keywords present
ok(bytes:find("/Type /Catalog", 1, true) ~= nil, "has Catalog")
ok(bytes:find("/Type /Pages", 1, true) ~= nil,   "has Pages tree")
ok(bytes:find("/Type /Page /Parent", 1, true) ~= nil, "has Page object")
ok(bytes:find("/Count 2", 1, true) ~= nil, "Pages /Count is 2")
ok(bytes:find("xref", 1, true) ~= nil, "has xref table")
ok(bytes:find("trailer", 1, true) ~= nil, "has trailer")
ok(bytes:find("startxref", 1, true) ~= nil, "has startxref")

-- Metadata went into Info dict
ok(bytes:find("(Hello PDF)", 1, true) ~= nil, "title in Info dict")
ok(bytes:find("(Tester)", 1, true) ~= nil, "author in Info dict")

-- Font registered + helvetica base font
ok(bytes:find("/BaseFont /Helvetica", 1, true) ~= nil, "Helvetica font emitted")

-- Link annotation
ok(bytes:find("/Subtype /Link", 1, true) ~= nil, "link annotation emitted")
ok(bytes:find("(https://example.com)", 1, true) ~= nil, "link URI emitted")

-- MediaBox: page two custom size 200x300
ok(bytes:find("0 0 200 300", 1, true) ~= nil, "page two MediaBox 200x300")
-- page one letter MediaBox
ok(bytes:find("0 0 612 792", 1, true) ~= nil, "page one MediaBox 612x792")

-- ===== save() writes a real file =========================================
local path = os.getenv("TEMP") .. "/clua_test_pdf_write.pdf"
local n = d:save(path)
ok(n == #bytes, "save() returns byte count == #to_bytes()")
do
    local f = io.open(path, "rb")
    ok(f ~= nil, "saved file is openable")
    if f then
        local on_disk = f:read("*a"); f:close()
        ok(on_disk == bytes, "saved bytes equal to_bytes() output")
    end
end

-- ===== error path: non-image bytes to page:image =========================
local bad = not pcall(function()
    local dd = pdf.doc()
    dd:add_page():image("not an image", 0, 0, 10, 10)
end)
ok(bad, "image() errors on non-PNG/JPEG data")

os.remove(path)
if fails == 0 then print("[+] PASS test_pdf_write") os.exit(0) else os.exit(1) end
