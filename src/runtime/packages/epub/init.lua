-- epub -- EPUB 2 / 3 ebook reader + writer.
--
-- An EPUB is a ZIP whose layout is:
--   mimetype                    -- literal "application/epub+zip", stored (no deflate)
--   META-INF/container.xml      -- points at the OPF package document
--   OEBPS/content.opf           -- manifest + spine + metadata (path varies)
--   OEBPS/toc.ncx               -- EPUB 2 TOC (DAISY NCX)
--   OEBPS/nav.xhtml             -- EPUB 3 navigation document
--   OEBPS/<chapters>.xhtml
--   OEBPS/images/<cover>.jpg
--
-- Public surface:
--   epub.open(path)        -> book
--     book:metadata()      -> { title, author, language, publisher,
--                               isbn, date, description, subjects = {...} }
--     book:cover()         -> bytes, format    (or nil)
--     book:chapters()      -> { { id, title, href, content_html, plain_text } }
--     book:toc()           -> nested { { label, href, children = {...} }, ... }
--     book:images()        -> { { name, content_type, data } }
--   epub.create()          -> writer
--     w:set_metadata(t)
--     w:add_chapter(title, html) -> id
--     w:set_cover(image_data, format)
--     w:save(path)

local M = {}

local zip = require "zip"
local xml = require "xml"

-- ===== Common helpers ====================================================

local function _strip_ns(tag)
    local i = tag:find(":", 1, true)
    if i then return tag:sub(i + 1) end
    return tag
end

local function _attr(node, name)
    if not node or not node.attrs then return nil end
    return node.attrs[name]
end

local function _first_child(node, want)
    if not node or not node.children then return nil end
    for _, c in ipairs(node.children) do
        if type(c) == "table" and _strip_ns(c.tag) == want then return c end
    end
end

local function _children_of(node, want)
    local out, n = {}, 0
    if not node or not node.children then return out end
    for _, c in ipairs(node.children) do
        if type(c) == "table" and _strip_ns(c.tag) == want then
            n = n + 1; out[n] = c
        end
    end
    return out
end

local function _all_children(node, want)
    -- Recursive find-all by tag.
    local out, n = {}, 0
    local function walk(node)
        if type(node) ~= "table" or not node.children then return end
        for _, c in ipairs(node.children) do
            if type(c) == "table" then
                if _strip_ns(c.tag) == want then n = n + 1; out[n] = c end
                walk(c)
            end
        end
    end
    walk(node)
    return out
end

local function xml_escape(s)
    return (tostring(s or ""):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
        ['"'] = "&quot;", ["'"] = "&apos;",
    }))
end

-- Strip HTML tags for plain text rendering of a chapter.
local function html_to_text(html)
    -- Drop scripts/styles entirely.
    html = html:gsub("<script.-</script>", " ")
    html = html:gsub("<style.-</style>", " ")
    -- Convert breaks/paragraphs to newlines.
    html = html:gsub("<br%s*/?>", "\n")
    html = html:gsub("</p>", "\n\n")
    html = html:gsub("</div>", "\n")
    html = html:gsub("</h[1-6]>", "\n\n")
    -- Strip remaining tags.
    html = html:gsub("<[^>]+>", "")
    -- Decode common entities.
    html = html:gsub("&([%w#]+);", function(e)
        if e == "amp"  then return "&" end
        if e == "lt"   then return "<" end
        if e == "gt"   then return ">" end
        if e == "quot" then return '"' end
        if e == "apos" then return "'" end
        if e == "nbsp" then return " " end
        if e:sub(1,2) == "#x" or e:sub(1,2) == "#X" then
            local cp = tonumber(e:sub(3), 16)
            if cp and utf8 and utf8.char then return utf8.char(cp) end
        elseif e:sub(1,1) == "#" then
            local cp = tonumber(e:sub(2))
            if cp and utf8 and utf8.char then return utf8.char(cp) end
        end
        return "&" .. e .. ";"
    end)
    -- Collapse runs of whitespace.
    html = html:gsub("[\r\n]+%s*[\r\n]+", "\n\n")
    return html
end

-- Resolve a relative path against a base path.
local function _path_join(base, rel)
    if rel:sub(1, 1) == "/" then return rel:sub(2) end
    local base_dir = base:match("^(.*/)") or ""
    -- Handle "../" segments.
    local combined = base_dir .. rel
    -- Collapse ".." segments.
    while true do
        local new = combined:gsub("[^/]+/%.%./", "", 1)
        if new == combined then break end
        combined = new
    end
    combined = combined:gsub("%./", "")
    return combined
end

-- ===== Reader ============================================================

local _book_mt = {}
_book_mt.__index = _book_mt

local function _find_opf(reader)
    local body = reader:read("META-INF/container.xml")
    local root = xml.parse(body)
    -- /container/rootfiles/rootfile@full-path
    local rfs = _first_child(root, "rootfiles")
    if not rfs then error("epub: container.xml has no rootfiles") end
    local rf = _first_child(rfs, "rootfile")
    if not rf then error("epub: container.xml has no rootfile") end
    return _attr(rf, "full-path")
end

local function _parse_opf(reader, opf_path)
    local body = reader:read(opf_path)
    local root = xml.parse(body)
    -- metadata
    local meta = { subjects = {} }
    local m = _first_child(root, "metadata")
    if m then
        for _, c in ipairs(m.children or {}) do
            if type(c) == "table" then
                local tag = _strip_ns(c.tag)
                local val = xml.text(c)
                if tag == "title"       then meta.title       = meta.title or val
                elseif tag == "creator" then meta.author      = meta.author or val
                elseif tag == "language" then meta.language   = val
                elseif tag == "publisher" then meta.publisher = val
                elseif tag == "date"     then meta.date       = val
                elseif tag == "description" then meta.description = val
                elseif tag == "subject"  then meta.subjects[#meta.subjects + 1] = val
                elseif tag == "identifier" then
                    -- An ISBN identifier is conventionally tagged via opf:scheme="ISBN"
                    -- or "urn:isbn:...".
                    local scheme = _attr(c, "scheme") or _attr(c, "opf:scheme") or ""
                    if scheme:lower() == "isbn" or val:match("^urn:isbn:") then
                        meta.isbn = val:gsub("^urn:isbn:", "")
                    end
                    meta.identifier = meta.identifier or val
                end
            end
        end
    end
    -- manifest: id -> { href, media-type, properties }
    local manifest = {}
    local man = _first_child(root, "manifest")
    if man then
        for _, item in ipairs(_children_of(man, "item")) do
            local id = _attr(item, "id")
            if id then
                manifest[id] = {
                    href       = _attr(item, "href"),
                    media_type = _attr(item, "media-type"),
                    properties = _attr(item, "properties") or "",
                }
            end
        end
    end
    -- spine: ordered list of itemrefs
    local spine = {}
    local sp = _first_child(root, "spine")
    if sp then
        for _, ir in ipairs(_children_of(sp, "itemref")) do
            spine[#spine + 1] = _attr(ir, "idref")
        end
        meta._ncx_id = _attr(sp, "toc")  -- EPUB 2 TOC ref
    end
    return meta, manifest, spine
end

local function _read_ncx(reader, opf_path, ncx_path)
    local full = _path_join(opf_path, ncx_path)
    local ok, body = pcall(reader.read, reader, full)
    if not ok or not body then return nil end
    local root = xml.parse(body)
    local navMap = _first_child(root, "navMap")
    local function walk(np)
        local entries = {}
        for _, n in ipairs(_children_of(np, "navPoint")) do
            local label_node = _first_child(n, "navLabel")
            local text_node  = label_node and _first_child(label_node, "text")
            local content    = _first_child(n, "content")
            entries[#entries + 1] = {
                label    = text_node and xml.text(text_node) or "",
                href     = content and _attr(content, "src") or "",
                children = walk(n),
            }
        end
        return entries
    end
    return walk(navMap)
end

local function _read_nav(reader, opf_path, nav_href)
    local full = _path_join(opf_path, nav_href)
    local ok, body = pcall(reader.read, reader, full)
    if not ok or not body then return nil end
    local root = xml.parse(body)
    -- Find nav[epub:type="toc"] -> ol
    local function find_nav(node)
        if type(node) ~= "table" then return nil end
        if _strip_ns(node.tag) == "nav" then
            local typ = _attr(node, "epub:type") or _attr(node, "type") or ""
            if typ:find("toc", 1, true) then return node end
        end
        for _, c in ipairs(node.children or {}) do
            if type(c) == "table" then
                local r = find_nav(c)
                if r then return r end
            end
        end
    end
    local nav_el = find_nav(root)
    if not nav_el then return nil end
    local function walk_ol(ol)
        local entries = {}
        for _, li in ipairs(_children_of(ol, "li")) do
            local a = _first_child(li, "a")
            local label = a and xml.text(a) or ""
            local href  = a and _attr(a, "href") or ""
            local kids  = {}
            for _, sub in ipairs(_children_of(li, "ol")) do
                local kid_entries = walk_ol(sub)
                for _, e in ipairs(kid_entries) do kids[#kids + 1] = e end
            end
            entries[#entries + 1] = {
                label = label, href = href, children = kids,
            }
        end
        return entries
    end
    local ol = _first_child(nav_el, "ol")
    if ol then return walk_ol(ol) end
    return {}
end

function _book_mt:metadata()
    if not self._meta_cache then
        local m = {}
        for k, v in pairs(self._meta) do m[k] = v end
        m._ncx_id = nil
        self._meta_cache = m
    end
    return self._meta_cache
end

function _book_mt:cover()
    -- EPUB 3: manifest item with properties="cover-image".
    for _, item in pairs(self._manifest) do
        if item.properties and item.properties:find("cover%-image") then
            local full = _path_join(self._opf_path, item.href)
            local ok, body = pcall(self._reader.read, self._reader, full)
            if ok then
                local fmt = item.media_type or "image/jpeg"
                fmt = fmt:gsub("^image/", "")
                return body, fmt
            end
        end
    end
    -- EPUB 2: metadata <meta name="cover" content="..."/> -> manifest id
    -- (Stored elsewhere; quick scan over the OPF.)
    local body = self._reader:read(self._opf_path)
    local cover_id = body:match('<meta%s+name=["\']cover["\']%s+content=["\']([^"\']+)')
                  or body:match('<meta%s+content=["\']([^"\']+)["\']%s+name=["\']cover["\']')
    if cover_id and self._manifest[cover_id] then
        local item = self._manifest[cover_id]
        local full = _path_join(self._opf_path, item.href)
        local ok, b = pcall(self._reader.read, self._reader, full)
        if ok then
            local fmt = item.media_type or "image/jpeg"
            fmt = fmt:gsub("^image/", "")
            return b, fmt
        end
    end
    return nil
end

function _book_mt:chapters()
    if self._chapters_cache then return self._chapters_cache end
    local out = {}
    for _, id in ipairs(self._spine) do
        local item = self._manifest[id]
        if item and item.href then
            local full = _path_join(self._opf_path, item.href)
            local ok, body = pcall(self._reader.read, self._reader, full)
            if ok and body then
                -- Try to extract a <title> for the chapter.
                local title = body:match("<title[^>]*>(.-)</title>")
                if not title then
                    title = body:match("<h1[^>]*>(.-)</h1>")
                end
                if title then title = title:gsub("<[^>]+>", "") end
                out[#out + 1] = {
                    id           = id,
                    title        = title or item.href,
                    href         = item.href,
                    content_html = body,
                    plain_text   = html_to_text(body),
                }
            end
        end
    end
    self._chapters_cache = out
    return out
end

function _book_mt:toc()
    if self._toc_cache then return self._toc_cache end
    -- EPUB 3: manifest item with properties="nav"
    for _, item in pairs(self._manifest) do
        if item.properties and item.properties:find("nav") then
            local toc = _read_nav(self._reader, self._opf_path, item.href)
            if toc then self._toc_cache = toc; return toc end
        end
    end
    -- EPUB 2: NCX file.
    if self._meta._ncx_id then
        local ncx_item = self._manifest[self._meta._ncx_id]
        if ncx_item then
            local toc = _read_ncx(self._reader, self._opf_path, ncx_item.href)
            if toc then self._toc_cache = toc; return toc end
        end
    end
    self._toc_cache = {}
    return self._toc_cache
end

function _book_mt:images()
    if self._images_cache then return self._images_cache end
    local out = {}
    for _, item in pairs(self._manifest) do
        if item.media_type and item.media_type:match("^image/") then
            local full = _path_join(self._opf_path, item.href)
            local ok, body = pcall(self._reader.read, self._reader, full)
            if ok then
                out[#out + 1] = {
                    name         = item.href,
                    content_type = item.media_type,
                    data         = body,
                }
            end
        end
    end
    self._images_cache = out
    return out
end

function M.open(path)
    local r = zip.open(path)
    local opf_path = _find_opf(r)
    local meta, manifest, spine = _parse_opf(r, opf_path)
    return setmetatable({
        _reader   = r,
        _opf_path = opf_path,
        _meta     = meta,
        _manifest = manifest,
        _spine    = spine,
    }, _book_mt)
end

-- ===== Writer ============================================================

local _w_mt = {}
_w_mt.__index = _w_mt

function _w_mt:set_metadata(t)
    for k, v in pairs(t) do self._meta[k] = v end
end

function _w_mt:add_chapter(title, html)
    self._chapter_seq = (self._chapter_seq or 0) + 1
    local id = "ch" .. self._chapter_seq
    self._chapters[#self._chapters + 1] = {
        id = id, title = title or ("Chapter " .. self._chapter_seq),
        html = html,
    }
    return id
end

function _w_mt:set_cover(image_data, format)
    self._cover = { data = image_data, format = (format or "jpeg"):lower() }
end

local function _media_for(ext)
    if ext == "png"  then return "image/png" end
    if ext == "jpg" or ext == "jpeg" then return "image/jpeg" end
    if ext == "gif"  then return "image/gif" end
    if ext == "svg"  then return "image/svg+xml" end
    return "application/octet-stream"
end

local function _build_container()
    return [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
end

local function _build_opf(meta, chapters, cover_ext)
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">',
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">',
        '<dc:identifier id="bookid">' ..
            xml_escape(meta.identifier or ("urn:uuid:" .. (meta.uuid or "luavm-epub-id"))) ..
            '</dc:identifier>',
        '<dc:title>' .. xml_escape(meta.title or "Untitled") .. '</dc:title>',
        '<dc:language>' .. xml_escape(meta.language or "en") .. '</dc:language>',
        '<meta property="dcterms:modified">' ..
            os.date("!%Y-%m-%dT%H:%M:%SZ") .. '</meta>',
    }
    if meta.author then
        pieces[#pieces + 1] = '<dc:creator>' .. xml_escape(meta.author) .. '</dc:creator>'
    end
    if meta.publisher then
        pieces[#pieces + 1] = '<dc:publisher>' .. xml_escape(meta.publisher) .. '</dc:publisher>'
    end
    if meta.date then
        pieces[#pieces + 1] = '<dc:date>' .. xml_escape(meta.date) .. '</dc:date>'
    end
    if meta.description then
        pieces[#pieces + 1] = '<dc:description>' .. xml_escape(meta.description) .. '</dc:description>'
    end
    if meta.subjects then
        for _, s in ipairs(meta.subjects) do
            pieces[#pieces + 1] = '<dc:subject>' .. xml_escape(s) .. '</dc:subject>'
        end
    end
    pieces[#pieces + 1] = '</metadata>'
    pieces[#pieces + 1] = '<manifest>'
    pieces[#pieces + 1] =
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    if cover_ext then
        pieces[#pieces + 1] = string.format(
            '<item id="cover-image" href="cover.%s" media-type="%s" properties="cover-image"/>',
            cover_ext, _media_for(cover_ext))
    end
    for _, ch in ipairs(chapters) do
        pieces[#pieces + 1] = string.format(
            '<item id="%s" href="%s.xhtml" media-type="application/xhtml+xml"/>',
            ch.id, ch.id)
    end
    pieces[#pieces + 1] = '</manifest>'
    pieces[#pieces + 1] = '<spine>'
    for _, ch in ipairs(chapters) do
        pieces[#pieces + 1] = '<itemref idref="' .. ch.id .. '"/>'
    end
    pieces[#pieces + 1] = '</spine>'
    pieces[#pieces + 1] = '</package>'
    return table.concat(pieces, "\n")
end

local function _build_nav(chapters)
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">',
        '<head><meta charset="utf-8"/><title>Table of Contents</title></head>',
        '<body><nav epub:type="toc"><h1>Contents</h1><ol>',
    }
    for _, ch in ipairs(chapters) do
        pieces[#pieces + 1] = string.format(
            '<li><a href="%s.xhtml">%s</a></li>',
            ch.id, xml_escape(ch.title))
    end
    pieces[#pieces + 1] = '</ol></nav></body></html>'
    return table.concat(pieces, "\n")
end

local function _build_chapter_xhtml(ch)
    -- Wrap user-supplied HTML in a valid XHTML skeleton if not already wrapped.
    local body = ch.html or ""
    if not body:match("<html") then
        body = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><meta charset="utf-8"/><title>%s</title></head>
<body>%s</body>
</html>]], xml_escape(ch.title), body)
    end
    return body
end

function _w_mt:save(path)
    local w = zip.create(path)
    -- The mimetype entry MUST be the first file and stored uncompressed.
    w:add_file("mimetype", "application/epub+zip", { method = "stored" })
    w:add_file("META-INF/container.xml", _build_container())
    local cover_ext = self._cover and self._cover.format or nil
    w:add_file("OEBPS/content.opf", _build_opf(self._meta, self._chapters, cover_ext))
    w:add_file("OEBPS/nav.xhtml", _build_nav(self._chapters))
    for _, ch in ipairs(self._chapters) do
        w:add_file("OEBPS/" .. ch.id .. ".xhtml", _build_chapter_xhtml(ch))
    end
    if self._cover then
        w:add_file("OEBPS/cover." .. self._cover.format, self._cover.data)
    end
    return w:close()
end

function M.create()
    return setmetatable({
        _meta     = {},
        _chapters = {},
        _cover    = nil,
    }, _w_mt)
end

return M
