-- tests/packages/test_epub.lua : epub writer -> reader round-trip.
-- Runner bundles epub + zip + xml + zlib, compiles, runs under JIT and -i,
-- byte-comparing stdout. Keep output deterministic (the writer bakes a
-- timestamp into the OPF, but we never read/print it).
local ok_req, epub = pcall(require, "epub")
if not ok_req then print("[~] SKIP test_epub (" .. tostring(epub) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_epub: " .. tostring(m)) end end

local path = os.getenv("TEMP") .. "/luavm_test_epub_rt.epub"

-- ===== Build a book ======================================================
local w = epub.create()
w:set_metadata({
    title       = "The Test Book",
    author      = "Jane Doe",
    language    = "en",
    publisher   = "LuaVM Press",
    identifier  = "urn:uuid:fixed-book-id-1234",
    subjects    = { "Fiction", "Testing" },
})
local id1 = w:add_chapter("Chapter One", "<h1>Chapter One</h1><p>It was a dark night.</p>")
local id2 = w:add_chapter("Chapter Two", "<h1>Chapter Two</h1><p>The sun rose.</p>")
ok(id1 == "ch1", "first chapter id is ch1")
ok(id2 == "ch2", "second chapter id is ch2")
-- a tiny fake JPEG cover (magic bytes only -- reader just stores/returns bytes)
local cover_bytes = "\xFF\xD8\xFFFAKEJPEGDATA"
w:set_cover(cover_bytes, "jpeg")
w:save(path)

-- ===== Read it back ======================================================
local book = epub.open(path)

-- metadata round-trip
local meta = book:metadata()
ok(meta.title == "The Test Book", "metadata title round-trips")
ok(meta.author == "Jane Doe",     "metadata author round-trips")
ok(meta.language == "en",         "metadata language round-trips")
ok(meta.publisher == "LuaVM Press","metadata publisher round-trips")
ok(#meta.subjects == 2,           "two subjects parsed")
-- subjects order is spine/document order (deterministic), assert both present
do
    local set = {}
    for _, s in ipairs(meta.subjects) do set[s] = true end
    ok(set["Fiction"] and set["Testing"], "both subjects present")
end

-- chapters round-trip in spine order
local chs = book:chapters()
ok(#chs == 2, "two chapters")
ok(chs[1].id == "ch1", "chapter[1] id ch1")
ok(chs[2].id == "ch2", "chapter[2] id ch2")
ok(chs[1].title == "Chapter One", "chapter[1] title from <title>")
ok(chs[1].content_html:find("dark night", 1, true) ~= nil, "chapter[1] html preserved")
-- plain_text strips tags
ok(chs[1].plain_text:find("It was a dark night", 1, true) ~= nil, "plain_text strips tags")
ok(chs[1].plain_text:find("<p>", 1, true) == nil, "plain_text has no tags")

-- toc: EPUB3 nav -> two entries pointing at chapters
local toc = book:toc()
ok(#toc == 2, "toc has two entries")
ok(toc[1].label == "Chapter One", "toc[1] label")
ok(toc[1].href:find("ch1", 1, true) ~= nil, "toc[1] href references ch1")

-- cover round-trip
local cdata, cfmt = book:cover()
ok(cdata == cover_bytes, "cover bytes round-trip")
ok(cfmt == "jpeg", "cover format is jpeg")

-- images: the cover counts as an image/jpeg manifest item
local imgs = book:images()
ok(#imgs == 1, "one image (the cover)")
ok(imgs[1].content_type == "image/jpeg", "image content_type image/jpeg")
ok(imgs[1].data == cover_bytes, "image data round-trips")

os.remove(path)
if fails == 0 then print("[+] PASS test_epub") os.exit(0) else os.exit(1) end
