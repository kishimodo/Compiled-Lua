-- docx -- Microsoft Word .docx reader + writer.
--
-- A .docx file is an Office Open XML (ECMA-376) package:
--   * ZIP container
--   * [Content_Types].xml        -- MIME map for every internal part
--   * _rels/.rels                -- package-level relationships
--   * word/document.xml          -- the WordprocessingML body
--   * word/_rels/document.xml.rels   -- target IDs (images, hyperlinks)
--   * word/media/*               -- embedded images
--   * docProps/core.xml          -- Dublin-Core-style metadata
--   * docProps/app.xml           -- application metadata
--
-- Public surface:
--   docx.open(path)              -> doc
--     doc:paragraphs()  -> iterator yielding paragraph tables
--     doc:tables()      -> array of tables (each is { rows = {{cells}} })
--     doc:images()      -> array of { name, content_type, data }
--     doc:text()        -> all paragraph text joined with newlines
--     doc:metadata()    -> { title, author, subject, ... }
--   docx.create()                -> writer
--     w:add_paragraph(text, opts?)
--     w:add_table(rows, opts?)
--     w:add_image(image_data, opts?)   opts: { format="png"|"jpeg", width_px, height_px }
--     w:add_page_break()
--     w:set_metadata(t)
--     w:save(path)

local M = {}

local zip = require "zip"
local xml = require "xml"

-- ===== Helpers ==========================================================

local function _strip_ns(tag)
    -- WordprocessingML tags are namespaced: "w:p", "w:r", etc.
    local i = tag:find(":", 1, true)
    if i then return tag:sub(i + 1) end
    return tag
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

local function _first_child(node, want)
    if not node or not node.children then return nil end
    for _, c in ipairs(node.children) do
        if type(c) == "table" and _strip_ns(c.tag) == want then return c end
    end
end

local function _attr(node, name)
    if not node or not node.attrs then return nil end
    -- attrs may be namespaced; try both.
    return node.attrs[name] or node.attrs["w:" .. name]
end

-- ===== Reader ===========================================================

local _doc_mt = {}
_doc_mt.__index = _doc_mt

local function _parse_run(r_node, styles_lookup, rels_lookup)
    -- Returns { text, bold, italic, underline, strike, font, size, color, hyperlink }
    local run = { text = "" }
    local rpr = _first_child(r_node, "rPr")
    if rpr then
        if _first_child(rpr, "b")      then run.bold      = true end
        if _first_child(rpr, "i")      then run.italic    = true end
        if _first_child(rpr, "u")      then run.underline = true end
        if _first_child(rpr, "strike") then run.strike    = true end
        local sz = _first_child(rpr, "sz")
        if sz then run.size = tonumber(_attr(sz, "val") or "0") / 2 end
        local color = _first_child(rpr, "color")
        if color then run.color = _attr(color, "val") end
        local rfonts = _first_child(rpr, "rFonts")
        if rfonts then run.font = _attr(rfonts, "ascii") end
    end
    -- Collect text spans -- <w:t> or <w:tab> or <w:br>
    local parts, np = {}, 0
    for _, c in ipairs(r_node.children or {}) do
        if type(c) == "table" then
            local tag = _strip_ns(c.tag)
            if tag == "t" then
                np = np + 1; parts[np] = xml.text(c)
            elseif tag == "tab" then
                np = np + 1; parts[np] = "\t"
            elseif tag == "br" then
                np = np + 1; parts[np] = "\n"
            end
        end
    end
    run.text = table.concat(parts)
    return run
end

local function _parse_paragraph(p_node, styles_lookup, rels_lookup)
    local para = { runs = {}, alignment = "left", style = nil }
    local ppr = _first_child(p_node, "pPr")
    if ppr then
        local st = _first_child(ppr, "pStyle")
        if st then para.style = _attr(st, "val") end
        local jc = _first_child(ppr, "jc")
        if jc then para.alignment = _attr(jc, "val") end
    end
    -- Children: runs (w:r) and hyperlinks (w:hyperlink wrapping runs).
    for _, c in ipairs(p_node.children or {}) do
        if type(c) == "table" then
            local tag = _strip_ns(c.tag)
            if tag == "r" then
                para.runs[#para.runs + 1] = _parse_run(c, styles_lookup, rels_lookup)
            elseif tag == "hyperlink" then
                local rid = _attr(c, "id") or c.attrs and c.attrs["r:id"]
                for _, rr in ipairs(c.children or {}) do
                    if type(rr) == "table" and _strip_ns(rr.tag) == "r" then
                        local run = _parse_run(rr, styles_lookup, rels_lookup)
                        run.hyperlink = rid and rels_lookup and rels_lookup[rid]
                        para.runs[#para.runs + 1] = run
                    end
                end
            end
        end
    end
    return para
end

local function _parse_table(tbl_node, styles_lookup, rels_lookup)
    local rows = {}
    for _, tr in ipairs(_children_of(tbl_node, "tr")) do
        local row = {}
        for _, tc in ipairs(_children_of(tr, "tc")) do
            -- Cell text: collect from all paragraphs/runs inside.
            local cell_parts = {}
            for _, p in ipairs(_children_of(tc, "p")) do
                local para = _parse_paragraph(p, styles_lookup, rels_lookup)
                local t_parts = {}
                for _, run in ipairs(para.runs) do t_parts[#t_parts + 1] = run.text end
                cell_parts[#cell_parts + 1] = table.concat(t_parts)
            end
            row[#row + 1] = table.concat(cell_parts, "\n")
        end
        rows[#rows + 1] = row
    end
    return { rows = rows }
end

local function _load_rels(reader)
    -- word/_rels/document.xml.rels => { rid -> target }
    local rels = {}
    local ok, body = pcall(reader.read, reader, "word/_rels/document.xml.rels")
    if not ok or not body then return rels end
    local root = xml.parse(body)
    for _, r in ipairs(root.children or {}) do
        if type(r) == "table" and _strip_ns(r.tag) == "Relationship" then
            local id = _attr(r, "Id")
            local target = _attr(r, "Target")
            local rtype  = _attr(r, "Type") or ""
            if id and target then
                rels[id] = { target = target, type = rtype }
            end
        end
    end
    return rels
end

local function _load_metadata(reader)
    local meta = {}
    local ok, body = pcall(reader.read, reader, "docProps/core.xml")
    if ok and body then
        local root = xml.parse(body)
        for _, c in ipairs(root.children or {}) do
            if type(c) == "table" then
                local tag = _strip_ns(c.tag)
                local val = xml.text(c)
                if tag == "title"       then meta.title       = val
                elseif tag == "creator" then meta.author      = val
                elseif tag == "subject" then meta.subject     = val
                elseif tag == "description" then meta.description = val
                elseif tag == "keywords" then meta.keywords   = val
                elseif tag == "lastModifiedBy" then meta.last_modified_by = val
                elseif tag == "created" then meta.created     = val
                elseif tag == "modified" then meta.modified   = val
                end
            end
        end
    end
    local ok2, body2 = pcall(reader.read, reader, "docProps/app.xml")
    if ok2 and body2 then
        local root = xml.parse(body2)
        for _, c in ipairs(root.children or {}) do
            if type(c) == "table" then
                local tag = _strip_ns(c.tag)
                local val = xml.text(c)
                if     tag == "Application" then meta.application = val
                elseif tag == "Company"     then meta.company     = val
                elseif tag == "Pages"       then meta.pages       = tonumber(val)
                elseif tag == "Words"       then meta.words       = tonumber(val)
                end
            end
        end
    end
    return meta
end

function _doc_mt:paragraphs()
    if not self._paragraphs_cache then
        local body = self._reader:read("word/document.xml")
        local root = xml.parse(body)
        local body_el = _first_child(root, "body")
        local paras = {}
        if body_el then
            for _, c in ipairs(body_el.children or {}) do
                if type(c) == "table" and _strip_ns(c.tag) == "p" then
                    paras[#paras + 1] = _parse_paragraph(c, nil, self._rels)
                end
            end
        end
        self._paragraphs_cache = paras
    end
    local i = 0
    local list = self._paragraphs_cache
    return function()
        i = i + 1
        return list[i]
    end
end

function _doc_mt:tables()
    if not self._tables_cache then
        local body = self._reader:read("word/document.xml")
        local root = xml.parse(body)
        local body_el = _first_child(root, "body")
        local tabs = {}
        if body_el then
            for _, c in ipairs(body_el.children or {}) do
                if type(c) == "table" and _strip_ns(c.tag) == "tbl" then
                    tabs[#tabs + 1] = _parse_table(c, nil, self._rels)
                end
            end
        end
        self._tables_cache = tabs
    end
    return self._tables_cache
end

function _doc_mt:images()
    if self._images_cache then return self._images_cache end
    local out = {}
    for _, e in ipairs(self._reader._reader:entries()) do
        if e.name:match("^word/media/") then
            local ext = e.name:match("%.([^%.]+)$") or ""
            local ct
            if ext == "png" then ct = "image/png"
            elseif ext == "jpg" or ext == "jpeg" then ct = "image/jpeg"
            elseif ext == "gif" then ct = "image/gif"
            else ct = "application/octet-stream" end
            local _data = self._reader:read(e.name)
            out[#out + 1] = {
                name         = e.name,
                content_type = ct,
                data         = _data,
            }
        end
    end
    self._images_cache = out
    return out
end

function _doc_mt:text()
    local parts = {}
    for para in self:paragraphs() do
        local t = {}
        for _, run in ipairs(para.runs) do t[#t + 1] = run.text end
        parts[#parts + 1] = table.concat(t)
    end
    return table.concat(parts, "\n")
end

function _doc_mt:metadata()
    if not self._meta_cache then self._meta_cache = _load_metadata(self._reader) end
    return self._meta_cache
end

function M.open(path)
    local r = zip.open(path)
    local rels = _load_rels(r)
    return setmetatable({
        _reader = r,
        _rels   = rels,
    }, _doc_mt)
end

-- ===== Writer ===========================================================

local _w_mt = {}
_w_mt.__index = _w_mt

local function xml_escape(s)
    return (tostring(s or ""):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
        ['"'] = "&quot;", ["'"] = "&apos;",
    }))
end

function _w_mt:add_paragraph(text, opts)
    opts = opts or {}
    local props = {}
    if opts.style then
        props[#props + 1] = '<w:pStyle w:val="' .. xml_escape(opts.style) .. '"/>'
    end
    if opts.alignment then
        props[#props + 1] = '<w:jc w:val="' .. xml_escape(opts.alignment) .. '"/>'
    end
    local rpr = {}
    if opts.bold      then rpr[#rpr + 1] = "<w:b/>" end
    if opts.italic    then rpr[#rpr + 1] = "<w:i/>" end
    if opts.underline then rpr[#rpr + 1] = '<w:u w:val="single"/>' end
    if opts.font_size then
        rpr[#rpr + 1] = '<w:sz w:val="' .. (opts.font_size * 2) .. '"/>'
    end
    if opts.color then
        local c = opts.color
        local hex
        if type(c) == "string" then
            hex = c:gsub("^#", "")
        else
            hex = string.format("%02X%02X%02X",
                c[1] or c.r or 0, c[2] or c.g or 0, c[3] or c.b or 0)
        end
        rpr[#rpr + 1] = '<w:color w:val="' .. hex .. '"/>'
    end
    if opts.font then
        rpr[#rpr + 1] = '<w:rFonts w:ascii="' .. xml_escape(opts.font) .. '"/>'
    end
    local rpr_xml = ""
    if #rpr > 0 then rpr_xml = "<w:rPr>" .. table.concat(rpr) .. "</w:rPr>" end
    local pPr_xml = ""
    if #props > 0 then pPr_xml = "<w:pPr>" .. table.concat(props) .. "</w:pPr>" end
    local run = string.format(
        '<w:r>%s<w:t xml:space="preserve">%s</w:t></w:r>',
        rpr_xml, xml_escape(text or ""))
    self._body[#self._body + 1] = "<w:p>" .. pPr_xml .. run .. "</w:p>"
end

function _w_mt:add_page_break()
    self._body[#self._body + 1] =
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'
end

function _w_mt:add_table(rows, opts)
    opts = opts or {}
    local cols = 0
    for _, r in ipairs(rows) do if #r > cols then cols = #r end end
    if cols == 0 then return end
    local pieces = { "<w:tbl>" }
    pieces[#pieces + 1] =
        '<w:tblPr><w:tblBorders>' ..
        '<w:top w:val="single" w:sz="4" w:color="000000"/>' ..
        '<w:left w:val="single" w:sz="4" w:color="000000"/>' ..
        '<w:bottom w:val="single" w:sz="4" w:color="000000"/>' ..
        '<w:right w:val="single" w:sz="4" w:color="000000"/>' ..
        '<w:insideH w:val="single" w:sz="4" w:color="000000"/>' ..
        '<w:insideV w:val="single" w:sz="4" w:color="000000"/>' ..
        '</w:tblBorders></w:tblPr>'
    pieces[#pieces + 1] = "<w:tblGrid>"
    for _ = 1, cols do
        pieces[#pieces + 1] = '<w:gridCol w:w="2000"/>'
    end
    pieces[#pieces + 1] = "</w:tblGrid>"
    for _, row in ipairs(rows) do
        pieces[#pieces + 1] = "<w:tr>"
        for c = 1, cols do
            local val = tostring(row[c] or "")
            pieces[#pieces + 1] = string.format(
                '<w:tc><w:p><w:r><w:t xml:space="preserve">%s</w:t></w:r></w:p></w:tc>',
                xml_escape(val))
        end
        pieces[#pieces + 1] = "</w:tr>"
    end
    pieces[#pieces + 1] = "</w:tbl>"
    -- A trailing empty paragraph is required after a table.
    pieces[#pieces + 1] = "<w:p/>"
    self._body[#self._body + 1] = table.concat(pieces)
end

function _w_mt:add_image(image_data, opts)
    opts = opts or {}
    local format = opts.format or "png"
    local ext = (format == "jpeg" or format == "jpg") and "jpeg" or "png"
    self._image_seq = (self._image_seq or 0) + 1
    local name = string.format("image%d.%s", self._image_seq, ext)
    local rid = "rId" .. tostring(100 + self._image_seq)
    self._media[#self._media + 1] = {
        name = name, data = image_data, ext = ext, rid = rid,
    }
    local w_px = opts.width_px  or 200
    local h_px = opts.height_px or 200
    -- EMUs: 9525 per pixel at 96 DPI.
    local w_emu = w_px * 9525
    local h_emu = h_px * 9525
    local drawing = string.format([[
<w:p><w:r>
<w:drawing>
  <wp:inline distT="0" distB="0" distL="0" distR="0">
    <wp:extent cx="%d" cy="%d"/>
    <wp:docPr id="%d" name="Picture %d"/>
    <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
          <pic:nvPicPr><pic:cNvPr id="%d" name="Picture %d"/><pic:cNvPicPr/></pic:nvPicPr>
          <pic:blipFill>
            <a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="%s"/>
            <a:stretch><a:fillRect/></a:stretch>
          </pic:blipFill>
          <pic:spPr>
            <a:xfrm><a:off x="0" y="0"/><a:ext cx="%d" cy="%d"/></a:xfrm>
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
          </pic:spPr>
        </pic:pic>
      </a:graphicData>
    </a:graphic>
  </wp:inline>
</w:drawing>
</w:r></w:p>]],
        w_emu, h_emu, self._image_seq, self._image_seq,
        self._image_seq, self._image_seq, rid, w_emu, h_emu)
    self._body[#self._body + 1] = drawing
end

function _w_mt:set_metadata(t)
    for k, v in pairs(t) do self._meta[k] = v end
end

local function _build_content_types(media)
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
        '<Default Extension="png" ContentType="image/png"/>',
        '<Default Extension="jpeg" ContentType="image/jpeg"/>',
        '<Default Extension="jpg" ContentType="image/jpeg"/>',
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>',
        '</Types>',
    }
    return table.concat(pieces)
end

local function _build_root_rels()
    return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>]]
end

local function _build_doc_rels(media)
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    }
    for _, m in ipairs(media) do
        pieces[#pieces + 1] = string.format(
            '<Relationship Id="%s" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/%s"/>',
            m.rid, m.name)
    end
    pieces[#pieces + 1] = '</Relationships>'
    return table.concat(pieces)
end

local function _build_document(body)
    return table.concat({
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"',
        ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
        ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
        ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">',
        '<w:body>', table.concat(body),
        '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>',
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>',
        '</w:sectPr>',
        '</w:body></w:document>',
    })
end

local function _build_core(meta)
    local function elem(name, v)
        if v == nil then return "" end
        return "<" .. name .. ">" .. xml_escape(v) .. "</" .. name .. ">"
    end
    return table.concat({
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<cp:coreProperties',
        ' xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"',
        ' xmlns:dc="http://purl.org/dc/elements/1.1/"',
        ' xmlns:dcterms="http://purl.org/dc/terms/"',
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
        elem("dc:title",       meta.title),
        elem("dc:creator",     meta.author or meta.creator),
        elem("dc:subject",     meta.subject),
        elem("dc:description", meta.description),
        elem("cp:keywords",    meta.keywords),
        '</cp:coreProperties>',
    })
end

local function _build_app(meta)
    return table.concat({
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"',
        ' xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">',
        '<Application>', xml_escape(meta.application or "CLua docx"), '</Application>',
        meta.company and ("<Company>" .. xml_escape(meta.company) .. "</Company>") or "",
        '</Properties>',
    })
end

function _w_mt:save(path)
    local w = zip.create(path)
    w:add_file("[Content_Types].xml", _build_content_types(self._media))
    w:add_file("_rels/.rels", _build_root_rels())
    w:add_file("word/document.xml", _build_document(self._body))
    w:add_file("word/_rels/document.xml.rels", _build_doc_rels(self._media))
    w:add_file("docProps/core.xml", _build_core(self._meta))
    w:add_file("docProps/app.xml", _build_app(self._meta))
    for _, m in ipairs(self._media) do
        w:add_file("word/media/" .. m.name, m.data)
    end
    return w:close()
end

function M.create()
    return setmetatable({
        _body  = {},
        _media = {},
        _meta  = {},
    }, _w_mt)
end

return M
