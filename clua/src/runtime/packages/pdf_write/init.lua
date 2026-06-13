-- pdf_write -- PDF 1.7 generator.
--
-- PDF file layout we emit:
--   %PDF-1.7
--   <object 1>   -- Catalog
--   <object 2>   -- Pages tree root
--   <object 3>   -- Info dictionary
--   <object N..> -- Page objects, Font objects, Content streams, Images
--   xref         -- cross-reference table
--   trailer
--   startxref
--   <offset of xref>
--   %%EOF
--
-- A page is an indirect object whose dictionary references a content
-- stream (the drawing instructions), plus a Resources dictionary listing
-- the fonts and XObjects (images) it draws with.
--
-- Public surface:
--   pdf_write.doc(opts?)   -> d
--     opts = { title, author, page_size = "letter"|"a4"|{w,h},
--              margins = { l, r, t, b } }
--   d:add_page(opts?)      -> page
--   d:save(path)           -> bytes_written
--   d:to_bytes()           -> string
--   page:text(s, x, y, opts?)
--     opts = { font="Helvetica"|"Times"|"Courier"|<full base14 name>,
--              size=12, color={r,g,b} }
--   page:line(x1, y1, x2, y2, opts?)         opts: { color, line_width }
--   page:rect(x, y, w, h, opts?)             opts: { color, fill, line_width }
--   page:circle(cx, cy, r, opts?)            opts: { color, fill, line_width }
--   page:image(image_data, x, y, w, h)
--   page:link({x,y,w,h}, url)

local M = {}

-- Soft zlib import for FlateDecode of content streams.
local _zlib_ok, zlib = pcall(require, "zlib")
if not _zlib_ok then zlib = nil end

-- ===== Page sizes (points; 1 pt = 1/72 in) ==============================
M.PAGE_SIZES = {
    letter = { 612, 792 },
    legal  = { 612, 1008 },
    a3     = { 842, 1191 },
    a4     = { 595, 842 },
    a5     = { 420, 595 },
    b5     = { 499, 708 },
}

-- ===== Helpers ===========================================================

local function pdf_escape_string(s)
    -- A literal PDF string is parenthesised; backslash and parens must be
    -- escaped. Non-ASCII bytes can pass through as-is.
    return "(" .. (s:gsub("\\", "\\\\"):gsub("%(", "\\("):gsub("%)", "\\)")) .. ")"
end

local function pdf_format_num(n)
    -- PDF doesn't accept exponential notation in real numbers.
    if math.type and math.type(n) == "integer" then
        return tostring(n)
    end
    return string.format("%g", n)
end

-- Standard 14 Type 1 fonts in PDF.
local _BASE_14 = {
    ["Helvetica"]              = true,
    ["Helvetica-Bold"]         = true,
    ["Helvetica-Oblique"]      = true,
    ["Helvetica-BoldOblique"]  = true,
    ["Times-Roman"]            = true,
    ["Times-Bold"]             = true,
    ["Times-Italic"]           = true,
    ["Times-BoldItalic"]       = true,
    ["Courier"]                = true,
    ["Courier-Bold"]           = true,
    ["Courier-Oblique"]        = true,
    ["Courier-BoldOblique"]    = true,
    ["Symbol"]                 = true,
    ["ZapfDingbats"]           = true,
}

local function _resolve_font(name)
    if _BASE_14[name] then return name end
    -- Friendly shorthand: "Times" -> "Times-Roman".
    if name == "Times" then return "Times-Roman" end
    if name == "Arial" then return "Helvetica" end
    return _BASE_14[name] and name or "Helvetica"
end

-- ===== PNG metadata helpers (needed for image emission) ==================

local function _parse_png(bytes)
    -- We need width, height, bit depth, color type, and the IDAT data.
    -- A PNG is: 8-byte signature + chain of chunks (length(4 BE), type(4),
    -- data, CRC(4)).
    if bytes:sub(1, 8) ~= "\x89PNG\r\n\x1A\n" then
        error("pdf_write.image: not a PNG")
    end
    local function be32(off)
        local a, b, c, d = bytes:byte(off, off + 3)
        return a * 16777216 + b * 65536 + c * 256 + d
    end
    local i = 9
    local width, height, bit_depth, color_type
    local idat = {}
    while i <= #bytes do
        local len  = be32(i)
        local ctype = bytes:sub(i + 4, i + 7)
        if ctype == "IHDR" then
            width      = be32(i + 8)
            height     = be32(i + 12)
            bit_depth  = bytes:byte(i + 16)
            color_type = bytes:byte(i + 17)
        elseif ctype == "IDAT" then
            idat[#idat + 1] = bytes:sub(i + 8, i + 7 + len)
        elseif ctype == "IEND" then
            break
        end
        i = i + 12 + len
    end
    return {
        width = width, height = height,
        bit_depth = bit_depth, color_type = color_type,
        idat = table.concat(idat),
    }
end

local function _parse_jpeg(bytes)
    -- Walk JPEG segments to find the first SOF (Start Of Frame).
    -- SOF markers: 0xFFC0..0xFFCF (except DHT 0xC4, DRI 0xC8, DRI 0xCC).
    if bytes:sub(1, 2) ~= "\xFF\xD8" then
        error("pdf_write.image: not a JPEG")
    end
    local i = 3
    while i < #bytes - 1 do
        if bytes:byte(i) ~= 0xFF then return nil end
        local marker = bytes:byte(i + 1)
        if (marker >= 0xC0 and marker <= 0xCF)
           and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
            -- SOF; segment data follows length-byte pair.
            local height = bytes:byte(i + 5) * 256 + bytes:byte(i + 6)
            local width  = bytes:byte(i + 7) * 256 + bytes:byte(i + 8)
            local depth  = bytes:byte(i + 4)
            local channels = bytes:byte(i + 9)
            return {
                width = width, height = height,
                bit_depth = depth, channels = channels,
            }
        end
        -- Skip segment: 2-byte length follows marker.
        local seg_len = bytes:byte(i + 2) * 256 + bytes:byte(i + 3)
        i = i + 2 + seg_len
    end
    return nil
end

-- ===== Document object ==================================================

local _doc_mt  = {}
_doc_mt.__index  = _doc_mt
local _page_mt = {}
_page_mt.__index = _page_mt

function M.doc(opts)
    opts = opts or {}
    local size
    if type(opts.page_size) == "table" then
        size = { opts.page_size[1] or opts.page_size.w,
                 opts.page_size[2] or opts.page_size.h }
    else
        size = M.PAGE_SIZES[opts.page_size or "letter"] or M.PAGE_SIZES.letter
    end
    local margins = opts.margins or { l = 72, r = 72, t = 72, b = 72 }
    if margins[1] then  -- array form
        margins = { l = margins[1], r = margins[2], t = margins[3], b = margins[4] }
    end
    return setmetatable({
        _title    = opts.title,
        _author   = opts.author,
        _page_w   = size[1],
        _page_h   = size[2],
        _margins  = margins,
        _pages    = {},
        _fonts    = {},  -- font name -> object id (lazy)
        _images   = {},  -- list of { width, height, object_id, data, filter, color_space, bits_per_component }
        _links    = {},  -- list of { page_idx, rect, url }
    }, _doc_mt)
end

function _doc_mt:add_page(opts)
    opts = opts or {}
    local page = setmetatable({
        _doc       = self,
        _width     = opts.width  or self._page_w,
        _height    = opts.height or self._page_h,
        _content   = {},
    }, _page_mt)
    self._pages[#self._pages + 1] = page
    return page
end

function _doc_mt:_register_font(name)
    name = _resolve_font(name)
    if self._fonts[name] then return self._fonts[name] end
    -- Assign a font alias used in the page's resource dict; the real obj
    -- id comes later when we lay objects out.
    local idx = 0
    for _ in pairs(self._fonts) do idx = idx + 1 end
    self._fonts[name] = { alias = "F" .. (idx + 1) }
    return self._fonts[name]
end

-- ===== Page drawing primitives ==========================================

local function _color_op(c)
    if not c then return nil end
    local r = c[1] or c.r or 0
    local g = c[2] or c.g or 0
    local b = c[3] or c.b or 0
    return string.format("%s %s %s",
        pdf_format_num(r), pdf_format_num(g), pdf_format_num(b))
end

function _page_mt:text(s, x, y, opts)
    opts = opts or {}
    local font   = self._doc:_register_font(opts.font or "Helvetica")
    local size   = opts.size or 12
    local pieces = { "BT" }
    if opts.color then
        pieces[#pieces + 1] = _color_op(opts.color) .. " rg"
    end
    -- PDF text coordinates are typically baseline -- caller provides those.
    pieces[#pieces + 1] = string.format("/%s %s Tf", font.alias, pdf_format_num(size))
    pieces[#pieces + 1] = string.format("%s %s Td",
        pdf_format_num(x), pdf_format_num(y))
    -- Allow \n in s to split into multiple lines using leading.
    local lines = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then lines[1] = "" end
    pieces[#pieces + 1] = string.format("%s TL", pdf_format_num(size * 1.2))
    pieces[#pieces + 1] = pdf_escape_string(lines[1]) .. " Tj"
    for i = 2, #lines do
        pieces[#pieces + 1] = "T*"
        pieces[#pieces + 1] = pdf_escape_string(lines[i]) .. " Tj"
    end
    pieces[#pieces + 1] = "ET"
    self._content[#self._content + 1] = table.concat(pieces, "\n")
end

function _page_mt:line(x1, y1, x2, y2, opts)
    opts = opts or {}
    local pieces = {}
    if opts.line_width then
        pieces[#pieces + 1] = pdf_format_num(opts.line_width) .. " w"
    end
    if opts.color then
        pieces[#pieces + 1] = _color_op(opts.color) .. " RG"
    end
    pieces[#pieces + 1] = string.format("%s %s m %s %s l S",
        pdf_format_num(x1), pdf_format_num(y1),
        pdf_format_num(x2), pdf_format_num(y2))
    self._content[#self._content + 1] = table.concat(pieces, "\n")
end

function _page_mt:rect(x, y, w, h, opts)
    opts = opts or {}
    local pieces = {}
    if opts.line_width then
        pieces[#pieces + 1] = pdf_format_num(opts.line_width) .. " w"
    end
    if opts.color and opts.fill then
        pieces[#pieces + 1] = _color_op(opts.color) .. " rg"
    elseif opts.color then
        pieces[#pieces + 1] = _color_op(opts.color) .. " RG"
    end
    pieces[#pieces + 1] = string.format("%s %s %s %s re",
        pdf_format_num(x), pdf_format_num(y),
        pdf_format_num(w), pdf_format_num(h))
    if opts.fill then
        pieces[#pieces + 1] = (opts.stroke == false) and "f" or "B"
    else
        pieces[#pieces + 1] = "S"
    end
    self._content[#self._content + 1] = table.concat(pieces, "\n")
end

function _page_mt:circle(cx, cy, r, opts)
    opts = opts or {}
    -- Bezier approximation with 4 cubic curves and the magic constant 0.5523.
    local k = 0.55228
    local pieces = {}
    if opts.line_width then
        pieces[#pieces + 1] = pdf_format_num(opts.line_width) .. " w"
    end
    if opts.color and opts.fill then
        pieces[#pieces + 1] = _color_op(opts.color) .. " rg"
    elseif opts.color then
        pieces[#pieces + 1] = _color_op(opts.color) .. " RG"
    end
    -- Helper assembles space-separated tokens without using a {...}
    -- table constructor (the CLua JIT can't lower OP_SETLIST B=0).
    local function p(a, b, c, d, e, f, g)
        if g ~= nil then
            return a .. " " .. b .. " " .. c .. " " .. d .. " " ..
                   e .. " " .. f .. " " .. g
        end
        return a .. " " .. b .. " " .. c
    end
    pieces[#pieces + 1] = p(pdf_format_num(cx + r), pdf_format_num(cy), "m")
    pieces[#pieces + 1] = p(
        pdf_format_num(cx + r), pdf_format_num(cy + r * k),
        pdf_format_num(cx + r * k), pdf_format_num(cy + r),
        pdf_format_num(cx), pdf_format_num(cy + r), "c")
    pieces[#pieces + 1] = p(
        pdf_format_num(cx - r * k), pdf_format_num(cy + r),
        pdf_format_num(cx - r), pdf_format_num(cy + r * k),
        pdf_format_num(cx - r), pdf_format_num(cy), "c")
    pieces[#pieces + 1] = p(
        pdf_format_num(cx - r), pdf_format_num(cy - r * k),
        pdf_format_num(cx - r * k), pdf_format_num(cy - r),
        pdf_format_num(cx), pdf_format_num(cy - r), "c")
    pieces[#pieces + 1] = p(
        pdf_format_num(cx + r * k), pdf_format_num(cy - r),
        pdf_format_num(cx + r), pdf_format_num(cy - r * k),
        pdf_format_num(cx + r), pdf_format_num(cy), "c")
    if opts.fill then
        pieces[#pieces + 1] = (opts.stroke == false) and "f" or "B"
    else
        pieces[#pieces + 1] = "S"
    end
    self._content[#self._content + 1] = table.concat(pieces, "\n")
end

function _page_mt:image(image_data, x, y, w, h)
    -- Decide format from magic.
    local img
    if image_data:sub(1, 8) == "\x89PNG\r\n\x1A\n" then
        img = _parse_png(image_data)
        img._kind = "png"
    elseif image_data:sub(1, 3) == "\xFF\xD8\xFF" then
        img = _parse_jpeg(image_data)
        img._kind = "jpeg"
        img.data = image_data
    else
        error("pdf_write.image: only PNG and JPEG accepted")
    end
    self._doc._images[#self._doc._images + 1] = img
    local alias = "Im" .. #self._doc._images
    img.alias = alias
    self._content[#self._content + 1] = string.format(
        "q %s 0 0 %s %s %s cm /%s Do Q",
        pdf_format_num(w), pdf_format_num(h),
        pdf_format_num(x), pdf_format_num(y), alias)
end

function _page_mt:link(rect, url)
    local page_idx
    for i, p in ipairs(self._doc._pages) do
        if p == self then page_idx = i; break end
    end
    self._doc._links[#self._doc._links + 1] = {
        page_idx = page_idx, rect = rect, url = url,
    }
end

-- ===== Object writer ====================================================

local function _emit_indirect(buf, id, body)
    -- Returns the byte offset of this object's "ID 0 obj" header.
    local offset = #buf[1]
    for i = 2, #buf do offset = offset + #buf[i] end
    buf[#buf + 1] = string.format("%d 0 obj\n%s\nendobj\n", id, body)
    return offset
end

local function _make_stream(body, filter)
    local payload = body
    local dict = string.format("<< /Length %d", #payload)
    if filter then dict = dict .. " /Filter /" .. filter end
    dict = dict .. " >>"
    return dict .. "\nstream\n" .. payload .. "\nendstream"
end

local function _maybe_flate(body)
    if zlib then
        return zlib.compress(body, 6, "zlib"), "FlateDecode"
    end
    return body, nil
end

function _doc_mt:to_bytes()
    local buf = { "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n" }
    local offsets = {}  -- id -> byte offset of the object's header
    local function emit(id, body)
        offsets[id] = _emit_indirect(buf, id, body)
    end
    -- Plan object IDs:
    --   1  = Catalog
    --   2  = Pages tree root
    --   3  = Info dictionary
    --   4..      = page objects, content streams, fonts, images, annots
    local next_id = 4

    -- Allocate font object IDs.
    local font_id = {}
    for name, info in pairs(self._fonts) do
        font_id[name] = next_id
        info.obj_id = next_id
        next_id = next_id + 1
    end

    -- Allocate image object IDs.
    for _, img in ipairs(self._images) do
        img.obj_id = next_id
        next_id = next_id + 1
    end

    -- Allocate page object IDs and their content stream IDs and annot IDs.
    local page_ids   = {}
    local content_ids = {}
    local annot_ids = {}  -- per-page array of annot ids
    for i, _ in ipairs(self._pages) do
        page_ids[i]    = next_id; next_id = next_id + 1
        content_ids[i] = next_id; next_id = next_id + 1
        annot_ids[i]   = {}
    end
    -- Allocate link annotation object IDs.
    for _, lnk in ipairs(self._links) do
        local id = next_id; next_id = next_id + 1
        lnk.obj_id = id
        local arr = annot_ids[lnk.page_idx]
        arr[#arr + 1] = id
    end

    -- 1: Catalog
    emit(1, "<< /Type /Catalog /Pages 2 0 R >>")
    -- 2: Pages tree
    do
        local kids = {}
        for _, id in ipairs(page_ids) do kids[#kids + 1] = string.format("%d 0 R", id) end
        emit(2, string.format(
            "<< /Type /Pages /Count %d /Kids [%s] >>",
            #page_ids, table.concat(kids, " ")))
    end
    -- 3: Info
    do
        local pieces = { "<<" }
        if self._title  then pieces[#pieces + 1] = "/Title "  .. pdf_escape_string(self._title)  end
        if self._author then pieces[#pieces + 1] = "/Author " .. pdf_escape_string(self._author) end
        pieces[#pieces + 1] = "/Producer (CLua pdf_write)"
        local now = os.date("!%Y%m%d%H%M%SZ")
        pieces[#pieces + 1] = "/CreationDate (D:" .. now .. ")"
        pieces[#pieces + 1] = ">>"
        emit(3, table.concat(pieces, " "))
    end
    -- Fonts
    for name, info in pairs(self._fonts) do
        emit(info.obj_id, string.format(
            "<< /Type /Font /Subtype /Type1 /BaseFont /%s /Encoding /WinAnsiEncoding >>",
            name))
    end
    -- Images
    for _, img in ipairs(self._images) do
        if img._kind == "jpeg" then
            local channels = img.channels or 3
            local cs = (channels == 1) and "/DeviceGray"
                    or (channels == 4) and "/DeviceCMYK"
                    or "/DeviceRGB"
            local body = img.data
            local stream = string.format(
                "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent %d /Filter /DCTDecode /Length %d >>\nstream\n%s\nendstream",
                img.width, img.height, cs, img.bit_depth or 8, #body, body)
            emit(img.obj_id, stream)
        else  -- PNG via FlateDecode
            -- PNG IDAT is already zlib-compressed and uses PNG's per-scanline
            -- filter prediction. We use the Predictor 15 (PNG up to optimum)
            -- to keep the original byte layout intact.
            local color_type = img.color_type
            local cs, colors
            if color_type == 0 then cs = "/DeviceGray"; colors = 1
            elseif color_type == 2 then cs = "/DeviceRGB";  colors = 3
            elseif color_type == 4 then cs = "/DeviceGray"; colors = 1  -- gray+alpha (alpha ignored)
            elseif color_type == 6 then cs = "/DeviceRGB";  colors = 3  -- rgb+alpha
            elseif color_type == 3 then
                -- Indexed PNG -- unsupported (would need PLTE handling).
                error("pdf_write.image: indexed PNGs unsupported; convert to RGB or grayscale")
            else
                error("pdf_write.image: unsupported PNG color_type " .. tostring(color_type))
            end
            local body = img.idat
            local stream = string.format(
                "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent %d /Filter /FlateDecode /DecodeParms << /Predictor 15 /Colors %d /BitsPerComponent %d /Columns %d >> /Length %d >>\nstream\n%s\nendstream",
                img.width, img.height, cs, img.bit_depth or 8,
                colors, img.bit_depth or 8, img.width,
                #body, body)
            emit(img.obj_id, stream)
        end
    end
    -- Pages + content streams + annots
    for i, page in ipairs(self._pages) do
        -- Resources
        local res = { "<< /Font <<" }
        for name, info in pairs(self._fonts) do
            res[#res + 1] = string.format("/%s %d 0 R", info.alias, info.obj_id)
        end
        res[#res + 1] = ">>"
        if #self._images > 0 then
            res[#res + 1] = "/XObject <<"
            for _, img in ipairs(self._images) do
                if img.alias then
                    res[#res + 1] = string.format("/%s %d 0 R", img.alias, img.obj_id)
                end
            end
            res[#res + 1] = ">>"
        end
        res[#res + 1] = ">>"
        -- Annotations list
        local annots = annot_ids[i]
        local annot_attr = ""
        if #annots > 0 then
            local refs = {}
            for _, id in ipairs(annots) do refs[#refs + 1] = string.format("%d 0 R", id) end
            annot_attr = " /Annots [" .. table.concat(refs, " ") .. "]"
        end
        local page_dict = string.format(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Resources %s /Contents %d 0 R%s >>",
            pdf_format_num(page._width), pdf_format_num(page._height),
            table.concat(res, " "),
            content_ids[i], annot_attr)
        emit(page_ids[i], page_dict)
        -- Content stream
        local raw = table.concat(page._content, "\n")
        local compressed, filter = _maybe_flate(raw)
        emit(content_ids[i], _make_stream(compressed, filter))
    end
    -- Link annotations
    for _, lnk in ipairs(self._links) do
        local r = lnk.rect
        local x = r[1] or r.x
        local y = r[2] or r.y
        local w = r[3] or r.w
        local h = r[4] or r.h
        local body = string.format(
            "<< /Type /Annot /Subtype /Link /Rect [%s %s %s %s] /Border [0 0 0] /A << /Type /Action /S /URI /URI %s >> >>",
            pdf_format_num(x), pdf_format_num(y),
            pdf_format_num(x + w), pdf_format_num(y + h),
            pdf_escape_string(lnk.url))
        emit(lnk.obj_id, body)
    end

    -- Cross-reference table.
    local xref_offset = 0
    for i = 1, #buf do xref_offset = xref_offset + #buf[i] end
    local total_objs = next_id - 1
    local xref = { "xref\n0 " .. (total_objs + 1) .. "\n",
                   "0000000000 65535 f \n" }
    for id = 1, total_objs do
        xref[#xref + 1] = string.format("%010d 00000 n \n", offsets[id] or 0)
    end
    buf[#buf + 1] = table.concat(xref)
    -- Trailer
    buf[#buf + 1] = string.format(
        "trailer\n<< /Size %d /Root 1 0 R /Info 3 0 R >>\nstartxref\n%d\n%%%%EOF\n",
        total_objs + 1, xref_offset)
    return table.concat(buf)
end

function _doc_mt:save(path)
    local s = self:to_bytes()
    local f = io.open(path, "wb")
    if not f then error("pdf_write.save: cannot open " .. path) end
    f:write(s); f:close()
    return #s
end

return M
