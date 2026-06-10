-- rtf -- Rich Text Format 1.9 parser + writer.
--
-- RTF is a token stream of three primitives:
--   * groups        -- { ... }
--   * control words -- \word, optionally followed by a signed integer
--   * literal text  -- everything else, with \\, \{, \} as escapes and
--                      \'xx as a single byte in the current code page.
--
-- The parser converts the raw token stream into a logical document model:
--   doc = {
--     metadata   = { title, author, subject, ... },
--     fonts      = { [n] = { name, family, charset } },
--     colors     = { [n] = { r, g, b } },
--     paragraphs = { { runs = { {text, bold, italic, underline,
--                                font, size, color}, ... },
--                      alignment = "left|center|right|justify",
--                      style = nil|"heading1"|... }, ... },
--   }
--
-- Public surface:
--   rtf.parse(s)         -> doc
--   rtf.to_text(d)       -> string         (d may be a doc or raw RTF)
--   rtf.to_html(rtf)     -> string
--   rtf.create()         -> writer object
--     writer:add_paragraph(text, opts?)
--     writer:add_bold(text)      writer:add_italic(text)
--     writer:add_underline(text)
--     writer:add_image(image_data, opts?)
--     writer:set_font(name)
--     writer:set_color(r, g, b)
--     writer:save(path)
--     writer:to_string()

local M = {}

-- ===== Tokeniser =========================================================

local function tokenise(s)
    local toks, n = {}, 0
    local i, len = 1, #s
    while i <= len do
        local c = s:sub(i, i)
        if c == "{" then
            n = n + 1; toks[n] = { type = "open" }
            i = i + 1
        elseif c == "}" then
            n = n + 1; toks[n] = { type = "close" }
            i = i + 1
        elseif c == "\\" then
            local nc = s:sub(i + 1, i + 1)
            if nc == "\\" or nc == "{" or nc == "}" then
                -- escaped literal
                n = n + 1; toks[n] = { type = "text", value = nc }
                i = i + 2
            elseif nc == "'" then
                -- \'xx hex byte
                local hex = s:sub(i + 2, i + 3)
                local b = tonumber(hex, 16)
                if b then
                    n = n + 1; toks[n] = { type = "text", value = string.char(b) }
                end
                i = i + 4
            elseif nc == "*" then
                -- destination indicator \* -- absorb, mark next control as optional
                n = n + 1; toks[n] = { type = "control", word = "*", param = nil }
                i = i + 2
            elseif nc == "\n" or nc == "\r" then
                -- ignore line continuation
                i = i + 2
            elseif nc:match("[A-Za-z]") then
                -- control word
                local j = i + 1
                while j <= len and s:sub(j, j):match("[A-Za-z]") do
                    j = j + 1
                end
                local word = s:sub(i + 1, j - 1)
                local param
                local p_start = j
                if s:sub(j, j) == "-" then j = j + 1 end
                while j <= len and s:sub(j, j):match("[0-9]") do
                    j = j + 1
                end
                if j > p_start then
                    param = tonumber(s:sub(p_start, j - 1))
                end
                -- Skip optional single trailing space (delimiter).
                if s:sub(j, j) == " " then j = j + 1 end
                n = n + 1; toks[n] = { type = "control", word = word, param = param }
                i = j
            else
                -- control symbol (single non-alpha char)
                n = n + 1; toks[n] = { type = "control", word = nc, param = nil }
                i = i + 2
            end
        elseif c == "\r" or c == "\n" then
            -- whitespace between tokens is irrelevant
            i = i + 1
        else
            -- run of literal text up to next backslash / brace
            local j = i
            while j <= len do
                local cc = s:sub(j, j)
                if cc == "\\" or cc == "{" or cc == "}" then break end
                j = j + 1
            end
            n = n + 1; toks[n] = { type = "text", value = s:sub(i, j - 1) }
            i = j
        end
    end
    return toks
end

-- ===== Parser ============================================================

local _DESTINATIONS = {
    fonttbl = true, colortbl = true, stylesheet = true, info = true,
    pict = true, header = true, footer = true, footnote = true,
    listtable = true, listoverridetable = true, rsidtbl = true,
    generator = true, datastore = true, themedata = true,
    latentstyles = true, lsdlockedexcept = true,
}

-- Style flags carried at parser state-frame level. Frames inherit on push.
local function new_state()
    return {
        bold       = false,
        italic     = false,
        underline  = false,
        strike     = false,
        font       = nil,
        size       = nil,
        color      = nil,
        alignment  = "left",
        style      = nil,
        in_dest    = nil,   -- destination name when current group is a destination
        skip_dest  = false, -- discard text inside this group
    }
end

local function clone_state(s)
    local n = new_state()
    for k, v in pairs(s) do n[k] = v end
    n.in_dest   = nil
    n.skip_dest = s.skip_dest
    return n
end

local function utf16_to_utf8(cp)
    if cp < 0 then cp = cp + 65536 end  -- RTF \uN can be signed
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + (cp >> 6), 0x80 + (cp & 0x3F))
    end
    return string.char(0xE0 + (cp >> 12),
                       0x80 + ((cp >> 6) & 0x3F),
                       0x80 + (cp & 0x3F))
end

function M.parse(s)
    if s:sub(1, 5) ~= "{\\rtf" then
        error("rtf: input does not start with {\\rtf")
    end
    local toks = tokenise(s)
    local doc = {
        metadata   = {},
        fonts      = {},
        colors     = {},
        paragraphs = {},
    }
    local cur_para = { runs = {}, alignment = "left", style = nil }
    local cur_text = {}
    -- Wrap the first frame in a fresh table assignment to avoid the JIT
    -- codegen path that fails on {func()} table constructors (the LuaVM
    -- bytecode emits OP_SETLIST B=0, which the JIT can't lower).
    local _init_state = new_state()
    local stack = {}
    stack[1] = _init_state
    local function top() return stack[#stack] end
    local function flush_run()
        if #cur_text == 0 then return end
        local st = top()
        local text = table.concat(cur_text)
        cur_text = {}
        if st.skip_dest then return end
        if st.in_dest then return end  -- handled separately
        cur_para.runs[#cur_para.runs + 1] = {
            text      = text,
            bold      = st.bold,
            italic    = st.italic,
            underline = st.underline,
            strike    = st.strike,
            font      = st.font,
            size      = st.size,
            color     = st.color,
        }
    end
    local function end_paragraph()
        flush_run()
        if #cur_para.runs > 0 or cur_para.style then
            doc.paragraphs[#doc.paragraphs + 1] = cur_para
        end
        local st = top()
        cur_para = { runs = {}, alignment = st.alignment, style = st.style }
    end

    -- Destination-specific state buffers.
    local dest_buf = nil  -- text inside metadata destination
    local cur_font = nil
    local cur_color = { r = 0, g = 0, b = 0 }
    local color_pending = false

    local skip_unicode_chars = 0

    local i, ntoks = 1, #toks
    while i <= ntoks do
        local t = toks[i]
        if t.type == "open" then
            local nst = clone_state(top())
            stack[#stack + 1] = nst
        elseif t.type == "close" then
            flush_run()
            local st = stack[#stack]
            if st.in_dest == "info_field" and dest_buf then
                -- Field text now lives in dest_buf with current_field_name on the frame.
                if st.field_name then
                    doc.metadata[st.field_name] = table.concat(dest_buf)
                end
                dest_buf = nil
            end
            stack[#stack] = nil
            if #stack == 0 then break end
        elseif t.type == "text" then
            local st = top()
            if skip_unicode_chars > 0 then
                -- The matching ANSI fallback that follows \uN may be one
                -- text byte; consume that many chars.
                local val = t.value
                if #val <= skip_unicode_chars then
                    skip_unicode_chars = skip_unicode_chars - #val
                else
                    t = { type = "text", value = val:sub(skip_unicode_chars + 1) }
                    skip_unicode_chars = 0
                end
            end
            if skip_unicode_chars == 0 and t.value ~= "" then
                if st.skip_dest then
                    -- discard
                elseif st.in_dest == "fonttbl" then
                    if cur_font then
                        local nm = t.value:gsub(";%s*$", "")
                        cur_font.name = nm
                    end
                elseif st.in_dest == "info_field" then
                    dest_buf = dest_buf or {}
                    dest_buf[#dest_buf + 1] = t.value
                elseif st.in_dest then
                    -- ignore other destinations
                else
                    cur_text[#cur_text + 1] = t.value
                end
            end
        elseif t.type == "control" then
            local w = t.word
            local p = t.param
            if w == "*" then
                -- Mark next group as optional/destination -- harmless to ignore here;
                -- destination tracking handled by destination names.
            elseif w == "par" or w == "line" then
                if w == "line" then
                    cur_text[#cur_text + 1] = "\n"
                else
                    end_paragraph()
                end
            elseif w == "pard" then
                flush_run()
                top().alignment = "left"
                top().style     = nil
                cur_para.alignment = "left"
                cur_para.style     = nil
            elseif w == "plain" then
                flush_run()
                local st = top()
                st.bold = false; st.italic = false; st.underline = false
                st.strike = false; st.size = nil; st.color = nil
            elseif w == "b" then
                flush_run()
                top().bold = (p == nil or p ~= 0)
            elseif w == "i" then
                flush_run()
                top().italic = (p == nil or p ~= 0)
            elseif w == "ul" or w == "ulw" then
                flush_run()
                top().underline = (p == nil or p ~= 0)
            elseif w == "ulnone" then
                flush_run()
                top().underline = false
            elseif w == "strike" then
                flush_run()
                top().strike = (p == nil or p ~= 0)
            elseif w == "fs" then
                flush_run()
                top().size = (p or 24) / 2  -- RTF stores half-points
            elseif w == "f" then
                flush_run()
                top().font = p
            elseif w == "cf" then
                flush_run()
                top().color = p
            elseif w == "ql" then top().alignment = "left";    cur_para.alignment = "left"
            elseif w == "qr" then top().alignment = "right";   cur_para.alignment = "right"
            elseif w == "qc" then top().alignment = "center";  cur_para.alignment = "center"
            elseif w == "qj" then top().alignment = "justify"; cur_para.alignment = "justify"
            elseif w == "s" then
                top().style = "style" .. tostring(p or 0)
                cur_para.style = top().style
            elseif w == "u" and p then
                -- \uN with optional skip count from \uc (default 1)
                cur_text[#cur_text + 1] = utf16_to_utf8(p)
                skip_unicode_chars = top().uc_skip or 1
            elseif w == "uc" then
                top().uc_skip = p or 1
            elseif w == "tab" then
                cur_text[#cur_text + 1] = "\t"
            elseif w == "emdash" then cur_text[#cur_text + 1] = "\xE2\x80\x94"
            elseif w == "endash" then cur_text[#cur_text + 1] = "\xE2\x80\x93"
            elseif w == "lquote" then cur_text[#cur_text + 1] = "\xE2\x80\x98"
            elseif w == "rquote" then cur_text[#cur_text + 1] = "\xE2\x80\x99"
            elseif w == "ldblquote" then cur_text[#cur_text + 1] = "\xE2\x80\x9C"
            elseif w == "rdblquote" then cur_text[#cur_text + 1] = "\xE2\x80\x9D"
            elseif w == "bullet" then cur_text[#cur_text + 1] = "\xE2\x80\xA2"
            elseif w == "~" then cur_text[#cur_text + 1] = " "   -- nbsp
            elseif w == "-" then  -- optional hyphen, render nothing
            elseif w == "_" then cur_text[#cur_text + 1] = "-"
            elseif w == "fonttbl" then
                top().in_dest = "fonttbl"
            elseif w == "f" and top().in_dest == "fonttbl" then
                -- handled above; this branch not reached
            elseif w == "colortbl" then
                top().in_dest = "colortbl"
                color_pending = true
                cur_color = { r = 0, g = 0, b = 0 }
                doc.colors[1] = { r = 0, g = 0, b = 0 }  -- auto color
            elseif w == "red" and top().in_dest == "colortbl" then
                cur_color.r = p or 0
            elseif w == "green" and top().in_dest == "colortbl" then
                cur_color.g = p or 0
            elseif w == "blue" and top().in_dest == "colortbl" then
                cur_color.b = p or 0
                -- Color entries are separated by ';' literal -- handled in text dispatch
            elseif w == "stylesheet" or w == "listtable" or w == "listoverridetable"
                or w == "generator" or w == "rsidtbl" or w == "themedata"
                or w == "datastore" or w == "latentstyles" then
                top().in_dest = w
                top().skip_dest = true
            elseif w == "info" then
                top().in_dest = "info"
            elseif w == "title" or w == "author" or w == "subject" or w == "keywords"
                or w == "operator" or w == "company" or w == "comment" then
                top().in_dest    = "info_field"
                top().field_name = w
                dest_buf = {}
            elseif w == "pict" then
                top().in_dest = "pict"
                top().skip_dest = true
            elseif w == "header" or w == "footer" then
                top().in_dest = w
                top().skip_dest = true
            elseif w == "footnote" then
                top().in_dest = "footnote"
                top().skip_dest = true
            elseif w == "ansi" or w == "mac" or w == "pc" or w == "pca" then
                doc.charset = w
            elseif w == "ansicpg" then
                doc.codepage = p
            elseif w == "deff" then
                doc.default_font = p
            end
            -- Inside fonttbl, \fN selects the font slot
            if top().in_dest == "fonttbl" and w == "f" then
                cur_font = { id = p }
                doc.fonts[p] = cur_font
            end
            -- Process color terminator inside colortbl
            if top().in_dest == "colortbl" then
                -- The literal ';' between color records arrives as text;
                -- we cannot detect here. Handled below.
            end
        end
        i = i + 1
    end
    -- Handle colortbl ';' separators: any text encountered inside colortbl
    -- with ';' triggers commit. Re-walk if needed -- simpler: extract from
    -- raw token stream specifically.
    do
        local in_ct = false
        local cur = { r = 0, g = 0, b = 0 }
        local pending = false
        local idx = 2  -- color index starts at 2 (1 = auto, set on \colortbl)
        -- The colortbl always opens with a leading ';' that terminates the
        -- implicit AUTO color -- which is already stored at colors[1]. Skipping
        -- that first empty separator (instead of committing a second auto entry
        -- at colors[2]) keeps the first real colour at colors[2], so \cf1
        -- resolves correctly (RTF-COLORTBL-001).
        local saw_first_sep = false
        for _, t in ipairs(toks) do
            if t.type == "control" then
                if t.word == "colortbl" then in_ct = true
                elseif t.word == "stylesheet" or t.word == "info" or t.word == "fonttbl" then
                    in_ct = false
                elseif in_ct then
                    if t.word == "red"   then cur.r = t.param or 0; pending = true
                    elseif t.word == "green" then cur.g = t.param or 0; pending = true
                    elseif t.word == "blue"  then cur.b = t.param or 0; pending = true
                    end
                end
            elseif t.type == "close" then
                if in_ct then in_ct = false end
            elseif t.type == "text" and in_ct then
                local txt = t.value
                for c in txt:gmatch(".") do
                    if c == ";" then
                        if not saw_first_sep and not pending then
                            -- leading ';' = the auto color (already colors[1]);
                            -- don't consume a real-color slot for it.
                            saw_first_sep = true
                        else
                            saw_first_sep = true
                            if pending then
                                doc.colors[idx] = { r = cur.r, g = cur.g, b = cur.b }
                            else
                                doc.colors[idx] = { r = 0, g = 0, b = 0 }
                            end
                            idx = idx + 1
                        end
                        cur = { r = 0, g = 0, b = 0 }
                        pending = false
                    end
                end
            end
        end
    end
    end_paragraph()
    return doc
end

-- ===== Render: to_text ===================================================

local function _is_doc(x)
    return type(x) == "table" and type(x.paragraphs) == "table"
end

function M.to_text(d)
    if type(d) == "string" then d = M.parse(d) end
    local out, n = {}, 0
    for _, para in ipairs(d.paragraphs) do
        for _, run in ipairs(para.runs) do
            n = n + 1; out[n] = run.text
        end
        n = n + 1; out[n] = "\n"
    end
    return table.concat(out)
end

-- ===== Render: to_html ===================================================

local function esc_html(s)
    return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

function M.to_html(rtf_or_doc)
    local d = type(rtf_or_doc) == "string" and M.parse(rtf_or_doc) or rtf_or_doc
    local out, n = {}, 0
    n = n + 1; out[n] = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
    if d.metadata and d.metadata.title then
        n = n + 1; out[n] = "<title>" .. esc_html(d.metadata.title) .. "</title>"
    end
    n = n + 1; out[n] = "</head><body>"
    for _, para in ipairs(d.paragraphs) do
        local align = para.alignment or "left"
        n = n + 1; out[n] = '<p style="text-align:' .. align .. ';">'
        for _, run in ipairs(para.runs) do
            local body = esc_html(run.text):gsub("\n", "<br>")
            local pieces = { body }
            if run.bold      then pieces = { "<b>",  table.concat(pieces), "</b>"  } end
            if run.italic    then pieces = { "<i>",  table.concat(pieces), "</i>"  } end
            if run.underline then pieces = { "<u>",  table.concat(pieces), "</u>"  } end
            if run.strike    then pieces = { "<s>",  table.concat(pieces), "</s>"  } end
            local style = {}
            if run.size  then style[#style + 1] = "font-size:" .. run.size .. "pt" end
            -- \cfN is 0-based with 0 = auto; colors[] is 1-based with [1] = auto,
            -- so \cfN maps to colors[N + 1] (\cf1 -> the first defined colour).
            if run.color and d.colors and d.colors[run.color + 1] then
                local c = d.colors[run.color + 1]
                style[#style + 1] = string.format("color:#%02x%02x%02x", c.r, c.g, c.b)
            end
            if #style > 0 then
                pieces = { '<span style="', table.concat(style, ";"), '">',
                           table.concat(pieces), "</span>" }
            end
            n = n + 1; out[n] = table.concat(pieces)
        end
        n = n + 1; out[n] = "</p>\n"
    end
    n = n + 1; out[n] = "</body></html>"
    return table.concat(out)
end

-- ===== Writer ============================================================

local _w_mt = {}
_w_mt.__index = _w_mt

local function escape_rtf_text(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b == 0x5C then out[#out + 1] = "\\\\"
        elseif b == 0x7B then out[#out + 1] = "\\{"
        elseif b == 0x7D then out[#out + 1] = "\\}"
        elseif b < 0x80 then out[#out + 1] = string.char(b)
        else
            -- UTF-8 multi-byte: decode codepoint, emit \uN?
            -- Decode UTF-8 lazily.
            local cp
            if b < 0xC0 then
                -- stray continuation; emit as \'hex
                out[#out + 1] = string.format("\\'%02x", b)
            elseif b < 0xE0 then
                local b2 = s:byte(i + 1) or 0
                cp = ((b & 0x1F) << 6) | (b2 & 0x3F)
            elseif b < 0xF0 then
                local b2 = s:byte(i + 1) or 0
                local b3 = s:byte(i + 2) or 0
                cp = ((b & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
            else
                local b2 = s:byte(i + 1) or 0
                local b3 = s:byte(i + 2) or 0
                local b4 = s:byte(i + 3) or 0
                cp = ((b & 0x07) << 18) | ((b2 & 0x3F) << 12)
                   | ((b3 & 0x3F) << 6) | (b4 & 0x3F)
            end
            if cp then
                -- RTF \uN with ?-replacement char (skip count = 1)
                if cp > 32767 then cp = cp - 65536 end
                out[#out + 1] = "\\u" .. tostring(cp) .. "?"
            end
        end
    end
    return table.concat(out)
end

function _w_mt:_color_index(r, g, b)
    -- Color 1 reserved as auto/black.
    for i, c in ipairs(self._colors) do
        if c.r == r and c.g == g and c.b == b then return i end
    end
    self._colors[#self._colors + 1] = { r = r, g = g, b = b }
    return #self._colors
end

function _w_mt:_font_index(name)
    for i, f in ipairs(self._fonts) do
        if f == name then return i - 1 end
    end
    self._fonts[#self._fonts + 1] = name
    return #self._fonts - 1
end

function _w_mt:set_font(name)
    self._cur_font = self:_font_index(name)
end

function _w_mt:set_color(r, g, b)
    self._cur_color = self:_color_index(r, g, b)
end

local function _para_open(opts)
    opts = opts or {}
    local pieces = { "\\pard" }
    if opts.alignment == "right"   then pieces[#pieces + 1] = "\\qr" end
    if opts.alignment == "center"  then pieces[#pieces + 1] = "\\qc" end
    if opts.alignment == "justify" then pieces[#pieces + 1] = "\\qj" end
    return table.concat(pieces) .. " "
end

function _w_mt:add_paragraph(text, opts)
    opts = opts or {}
    -- Same JIT-codegen workaround as in parse() -- avoid {func()} literal.
    local _open = _para_open(opts)
    local pieces = {}
    pieces[1] = _open
    if opts.font then
        pieces[#pieces + 1] = "\\f" .. self:_font_index(opts.font)
    elseif self._cur_font then
        pieces[#pieces + 1] = "\\f" .. self._cur_font
    end
    if opts.font_size then
        pieces[#pieces + 1] = "\\fs" .. (opts.font_size * 2)
    end
    if opts.color then
        local c = opts.color
        pieces[#pieces + 1] = "\\cf" .. self:_color_index(c[1] or c.r,
                                                          c[2] or c.g,
                                                          c[3] or c.b)
    elseif self._cur_color then
        pieces[#pieces + 1] = "\\cf" .. self._cur_color
    end
    if opts.bold      then pieces[#pieces + 1] = "\\b" end
    if opts.italic    then pieces[#pieces + 1] = "\\i" end
    if opts.underline then pieces[#pieces + 1] = "\\ul" end
    if opts.style then
        -- Map simple style names to RTF style indices we register.
        local sname = opts.style:lower()
        if sname:match("^heading(%d)$") or sname == "title" then
            local lvl = tonumber(sname:match("(%d)$")) or 1
            pieces[#pieces + 1] = "\\s" .. lvl
            pieces[#pieces + 1] = "\\fs" .. tostring(40 - 4 * lvl)
            pieces[#pieces + 1] = "\\b"
        end
    end
    pieces[#pieces + 1] = " "
    pieces[#pieces + 1] = escape_rtf_text(text or "")
    pieces[#pieces + 1] = "\\par\n"
    self._body[#self._body + 1] = table.concat(pieces)
end

function _w_mt:add_bold(text)
    self._body[#self._body + 1] = "{\\b " .. escape_rtf_text(text) .. "}"
end

function _w_mt:add_italic(text)
    self._body[#self._body + 1] = "{\\i " .. escape_rtf_text(text) .. "}"
end

function _w_mt:add_underline(text)
    self._body[#self._body + 1] = "{\\ul " .. escape_rtf_text(text) .. "}"
end

function _w_mt:add_image(image_data, opts)
    opts = opts or {}
    -- RTF embeds binary images as hex inside a \pict group.
    local format = opts.format or "png"
    local fmt_word = (format == "jpeg" or format == "jpg") and "\\jpegblip" or "\\pngblip"
    local w = opts.width  or 100
    local h = opts.height or 100
    local hex_parts, hn = {}, 0
    for i = 1, #image_data do
        hn = hn + 1; hex_parts[hn] = string.format("%02x", image_data:byte(i))
    end
    self._body[#self._body + 1] = string.format(
        "{\\pict%s\\picw%d\\pich%d\\picwgoal%d\\pichgoal%d\n%s\n}",
        fmt_word, w, h, w * 15, h * 15, table.concat(hex_parts))
end

function _w_mt:add_page_break()
    self._body[#self._body + 1] = "\\page\n"
end

function _w_mt:add_table(rows, opts)
    opts = opts or {}
    local cols = 0
    for _, r in ipairs(rows) do
        if #r > cols then cols = #r end
    end
    if cols == 0 then return end
    local col_w = math.floor(9000 / cols)  -- twips, fits letter-page width
    for _, row in ipairs(rows) do
        local pieces = { "\\trowd\\trgaph100" }
        for c = 1, cols do
            pieces[#pieces + 1] = "\\cellx" .. (col_w * c)
        end
        self._body[#self._body + 1] = table.concat(pieces)
        for c = 1, cols do
            self._body[#self._body + 1] = "\\pard\\intbl " ..
                escape_rtf_text(tostring(row[c] or "")) .. "\\cell"
        end
        self._body[#self._body + 1] = "\\row\n"
    end
end

function _w_mt:set_metadata(t)
    for k, v in pairs(t) do self._meta[k] = v end
end

function _w_mt:to_string()
    local hdr = { "{\\rtf1\\ansi\\ansicpg1252\\deff0" }
    -- Font table
    hdr[#hdr + 1] = "{\\fonttbl"
    for i, name in ipairs(self._fonts) do
        hdr[#hdr + 1] = string.format("{\\f%d\\fnil %s;}", i - 1, name)
    end
    hdr[#hdr + 1] = "}"
    -- Color table: leading ';' for auto color.
    hdr[#hdr + 1] = "{\\colortbl;"
    for _, c in ipairs(self._colors) do
        hdr[#hdr + 1] = string.format("\\red%d\\green%d\\blue%d;", c.r, c.g, c.b)
    end
    hdr[#hdr + 1] = "}"
    -- Info group (metadata)
    if next(self._meta) then
        hdr[#hdr + 1] = "{\\info"
        for k, v in pairs(self._meta) do
            hdr[#hdr + 1] = string.format("{\\%s %s}", k, escape_rtf_text(tostring(v)))
        end
        hdr[#hdr + 1] = "}"
    end
    hdr[#hdr + 1] = "\\fs24\n"
    hdr[#hdr + 1] = table.concat(self._body)
    hdr[#hdr + 1] = "}"
    return table.concat(hdr)
end

function _w_mt:save(path)
    local s = self:to_string()
    local f = io.open(path, "wb")
    if not f then error("rtf.save: cannot open " .. path) end
    f:write(s); f:close()
    return #s
end

function M.create()
    return setmetatable({
        _fonts  = { "Calibri" },
        _colors = {},
        _body   = {},
        _meta   = {},
        _cur_font  = nil,
        _cur_color = nil,
    }, _w_mt)
end

return M
