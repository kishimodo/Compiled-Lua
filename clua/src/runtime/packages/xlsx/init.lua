-- xlsx -- Microsoft Excel .xlsx reader + writer.
--
-- A .xlsx is an Office Open XML SpreadsheetML package:
--   * [Content_Types].xml
--   * _rels/.rels                          -- root relationships
--   * xl/workbook.xml                      -- sheet enumeration
--   * xl/_rels/workbook.xml.rels           -- sheet ID -> target
--   * xl/sharedStrings.xml                 -- de-duplicated string pool
--   * xl/worksheets/sheet<N>.xml           -- one per sheet
--   * xl/styles.xml                        -- number formats / fonts
--
-- Cells in a sheet look like:
--   <c r="A1" t="s"><v>0</v></c>           -- shared string (index)
--   <c r="B1"><v>3.14</v></c>              -- number
--   <c r="C1" t="b"><v>1</v></c>           -- boolean
--   <c r="D1" t="inlineStr"><is><t>x</t></is></c>
--   <c r="E1" t="str"><v>foo</v></c>       -- formula result string
--
-- Public surface:
--   xlsx.open(path)             -> wb
--     wb:sheet_names()          -> { name, ... }
--     wb:sheet(name_or_idx)     -> sheet
--     wb:to_csv(name?)          -> string
--   sheet:rows()                -> iterator -> array
--   sheet:cell(addr_or_row,col?)-> value
--   sheet:dimensions()          -> { min_row, max_row, min_col, max_col }
--   sheet:column(letter_or_idx) -> array of column values
--   sheet:to_records()          -> { { [hdr] = val, ... }, ... }
--   xlsx.create()               -> wb
--     wb:add_sheet(name)        -> sheet
--     wb:save(path)
--   sheet:set(row, col, value)
--   sheet:set_a1(addr, value)
--   sheet:add_row(values)
--   sheet:set_format(range, opts)   opts = { number_format=..., bold=..., italic=... }

local M = {}

local zip = require "zip"
local xml = require "xml"

-- ===== A1 helpers ========================================================

local function col_letter_to_index(letter)
    local n = 0
    for i = 1, #letter do
        local c = letter:byte(i)
        if c < 65 or c > 90 then return nil end
        n = n * 26 + (c - 64)
    end
    return n
end

local function col_index_to_letter(idx)
    local out = ""
    while idx > 0 do
        idx = idx - 1
        out = string.char(65 + idx % 26) .. out
        idx = math.floor(idx / 26)
    end
    return out
end

local function parse_a1(addr)
    local col, row = addr:match("^([A-Z]+)(%d+)$")
    if not col then return nil end
    return tonumber(row), col_letter_to_index(col)
end

local function build_a1(row, col)
    return col_index_to_letter(col) .. tostring(row)
end

M.col_letter = col_index_to_letter
M.col_index  = col_letter_to_index
M.parse_a1   = parse_a1
M.build_a1   = build_a1

-- ===== XML helpers =======================================================

local function _strip_ns(tag)
    local i = tag:find(":", 1, true)
    if i then return tag:sub(i + 1) end
    return tag
end

local function _attr(node, name)
    if not node or not node.attrs then return nil end
    return node.attrs[name]
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

local function xml_escape(s)
    return (tostring(s or ""):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
        ['"'] = "&quot;", ["'"] = "&apos;",
    }))
end

-- ===== Reader ============================================================

local _sheet_mt = {}
_sheet_mt.__index = _sheet_mt

local _wb_mt = {}
_wb_mt.__index = _wb_mt

local function _load_shared_strings(reader)
    local out = {}
    local ok, body = pcall(reader.read, reader, "xl/sharedStrings.xml")
    if not ok or not body then return out end
    local root = xml.parse(body)
    local i = 0
    for _, si in ipairs(_children_of(root, "si")) do
        -- <si> may contain a single <t>, or multiple <r><t> for rich text.
        local parts = {}
        for _, c in ipairs(si.children or {}) do
            if type(c) == "table" then
                local tag = _strip_ns(c.tag)
                if tag == "t" then
                    parts[#parts + 1] = xml.text(c)
                elseif tag == "r" then
                    local t = _first_child(c, "t")
                    if t then parts[#parts + 1] = xml.text(t) end
                end
            end
        end
        out[i] = table.concat(parts)
        i = i + 1
    end
    return out
end

local function _load_workbook(reader)
    local body = reader:read("xl/workbook.xml")
    local root = xml.parse(body)
    local sheets_node = _first_child(root, "sheets")
    local list = {}
    for idx, s in ipairs(_children_of(sheets_node, "sheet")) do
        list[#list + 1] = {
            name   = _attr(s, "name") or ("Sheet" .. idx),
            sheetId = tonumber(_attr(s, "sheetId") or idx),
            rid    = _attr(s, "r:id") or (s.attrs and s.attrs["r:id"]) or "",
            index  = idx,
        }
    end
    -- Workbook rels map rid -> target.
    local rels = {}
    local ok, rbody = pcall(reader.read, reader, "xl/_rels/workbook.xml.rels")
    if ok and rbody then
        local rroot = xml.parse(rbody)
        for _, r in ipairs(rroot.children or {}) do
            if type(r) == "table" and _strip_ns(r.tag) == "Relationship" then
                local id = _attr(r, "Id")
                local target = _attr(r, "Target")
                if id and target then rels[id] = target end
            end
        end
    end
    for _, sh in ipairs(list) do
        local t = rels[sh.rid] or ("worksheets/sheet" .. sh.index .. ".xml")
        if not t:match("^xl/") then t = "xl/" .. t end
        sh.path = t
    end
    return list
end

local function _parse_cell_value(c_node, shared)
    local t = _attr(c_node, "t") or "n"
    if t == "inlineStr" then
        local is = _first_child(c_node, "is")
        if is then return xml.text(is) end
        return ""
    end
    local v = _first_child(c_node, "v")
    if not v then
        -- Maybe inline <t>
        local tt = _first_child(c_node, "t")
        if tt then return xml.text(tt) end
        return nil
    end
    local raw = xml.text(v)
    if t == "s" then
        local idx = tonumber(raw)
        if idx and shared[idx] then return shared[idx] end
        return raw
    elseif t == "b" then
        return raw == "1" or raw == "true"
    elseif t == "str" or t == "e" then
        return raw
    else
        -- numeric
        return tonumber(raw) or raw
    end
end

local function _load_sheet(reader, sheet_info, shared)
    local body = reader:read(sheet_info.path)
    local root = xml.parse(body)
    local sheet_data = _first_child(root, "sheetData")
    -- cells[row][col] = value
    local cells = {}
    local min_row, max_row = math.huge, 0
    local min_col, max_col = math.huge, 0
    if sheet_data then
        for _, row_node in ipairs(_children_of(sheet_data, "row")) do
            local r = tonumber(_attr(row_node, "r"))
            for _, c in ipairs(_children_of(row_node, "c")) do
                local addr = _attr(c, "r")
                local rr, cc
                if addr then rr, cc = parse_a1(addr) else rr = r end
                if rr and cc then
                    local v = _parse_cell_value(c, shared)
                    cells[rr] = cells[rr] or {}
                    cells[rr][cc] = v
                    if rr < min_row then min_row = rr end
                    if rr > max_row then max_row = rr end
                    if cc < min_col then min_col = cc end
                    if cc > max_col then max_col = cc end
                end
            end
        end
    end
    if max_row == 0 then
        min_row, max_row, min_col, max_col = 1, 1, 1, 1
    end
    -- Dimension hint if present
    local dim = _first_child(root, "dimension")
    if dim then
        local ref = _attr(dim, "ref")
        if ref then
            local a, b = ref:match("^(%S+):(%S+)$")
            if a and b then
                local r1, c1 = parse_a1(a)
                local r2, c2 = parse_a1(b)
                if r1 then
                    if r1 < min_row then min_row = r1 end
                    if r2 > max_row then max_row = r2 end
                    if c1 < min_col then min_col = c1 end
                    if c2 > max_col then max_col = c2 end
                end
            end
        end
    end
    return setmetatable({
        _name  = sheet_info.name,
        _cells = cells,
        _dims  = { min_row = min_row, max_row = max_row,
                   min_col = min_col, max_col = max_col },
    }, _sheet_mt)
end

function _sheet_mt:name() return self._name end

function _sheet_mt:dimensions()
    return {
        min_row = self._dims.min_row, max_row = self._dims.max_row,
        min_col = self._dims.min_col, max_col = self._dims.max_col,
    }
end

function _sheet_mt:cell(a, b)
    if type(a) == "string" then
        local r, c = parse_a1(a)
        if not r then return nil end
        return self._cells[r] and self._cells[r][c]
    end
    return self._cells[a] and self._cells[a][b]
end

function _sheet_mt:rows()
    local r = self._dims.min_row - 1
    local max_r = self._dims.max_row
    local max_c = self._dims.max_col
    return function()
        r = r + 1
        if r > max_r then return nil end
        local row = self._cells[r] or {}
        local out = {}
        for c = self._dims.min_col, max_c do
            out[c - self._dims.min_col + 1] = row[c]
        end
        return out, r
    end
end

function _sheet_mt:column(letter_or_idx)
    local idx
    if type(letter_or_idx) == "string" then
        idx = col_letter_to_index(letter_or_idx)
    else
        idx = letter_or_idx
    end
    local out = {}
    for r = self._dims.min_row, self._dims.max_row do
        out[#out + 1] = self._cells[r] and self._cells[r][idx]
    end
    return out
end

function _sheet_mt:to_records()
    local iter = self:rows()
    local header = iter()
    if not header then return {} end
    local recs = {}
    for row in iter do
        local rec = {}
        for i, h in ipairs(header) do
            if h ~= nil and h ~= "" then rec[tostring(h)] = row[i] end
        end
        recs[#recs + 1] = rec
    end
    return recs
end

local function _csv_escape(v)
    if v == nil then return "" end
    local s = tostring(v)
    if s:find("[,\"\n\r]") then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

function _wb_mt:sheet_names()
    local names = {}
    for _, s in ipairs(self._sheets_info) do names[#names + 1] = s.name end
    return names
end

function _wb_mt:sheet(name_or_idx)
    if type(name_or_idx) == "number" then
        local info = self._sheets_info[name_or_idx]
        if not info then return nil end
        return _load_sheet(self._reader, info, self._shared)
    end
    for _, info in ipairs(self._sheets_info) do
        if info.name == name_or_idx then
            return _load_sheet(self._reader, info, self._shared)
        end
    end
    return nil
end

function _wb_mt:to_csv(name)
    local sheet = name and self:sheet(name) or self:sheet(1)
    if not sheet then return "" end
    local lines = {}
    for row in sheet:rows() do
        local cols = {}
        for i, v in ipairs(row) do cols[i] = _csv_escape(v) end
        lines[#lines + 1] = table.concat(cols, ",")
    end
    return table.concat(lines, "\n")
end

function M.open(path)
    local r = zip.open(path)
    local shared = _load_shared_strings(r)
    local sheets = _load_workbook(r)
    return setmetatable({
        _reader = r,
        _shared = shared,
        _sheets_info = sheets,
    }, _wb_mt)
end

-- ===== Writer ============================================================

local _wsheet_mt = {}
_wsheet_mt.__index = _wsheet_mt

local _wwb_mt = {}
_wwb_mt.__index = _wwb_mt

function _wsheet_mt:set(row, col, value)
    self._cells[row] = self._cells[row] or {}
    self._cells[row][col] = value
    if row > self._max_row then self._max_row = row end
    if col > self._max_col then self._max_col = col end
end

function _wsheet_mt:set_a1(addr, value)
    local r, c = parse_a1(addr)
    if not r then error("xlsx: bad A1 address " .. tostring(addr)) end
    self:set(r, c, value)
end

function _wsheet_mt:add_row(values)
    self._next_row = (self._next_row or 0) + 1
    for i, v in ipairs(values) do self:set(self._next_row, i, v) end
end

function _wsheet_mt:set_format(range, opts)
    -- Stash a formatting record keyed by range. The writer maps these
    -- to style indices when serialising.
    self._fmts = self._fmts or {}
    self._fmts[#self._fmts + 1] = { range = range, opts = opts or {} }
end

local function _value_to_xml(v, shared_pool, shared_index)
    if v == nil then return nil end
    local t = type(v)
    if t == "number" then
        return "n", tostring(v)
    elseif t == "boolean" then
        return "b", v and "1" or "0"
    else
        local s = tostring(v)
        local idx = shared_index[s]
        if idx == nil then
            idx = #shared_pool
            shared_pool[idx + 1] = s
            shared_index[s] = idx
        end
        return "s", tostring(idx)
    end
end

local function _build_sheet_xml(sheet, shared_pool, shared_index, style_for_cell)
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"',
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    }
    if sheet._max_row > 0 and sheet._max_col > 0 then
        pieces[#pieces + 1] = string.format(
            '<dimension ref="A1:%s"/>',
            build_a1(sheet._max_row, sheet._max_col))
    end
    pieces[#pieces + 1] = '<sheetData>'
    for r = 1, sheet._max_row do
        local row = sheet._cells[r]
        if row then
            pieces[#pieces + 1] = string.format('<row r="%d">', r)
            for c = 1, sheet._max_col do
                local v = row[c]
                if v ~= nil then
                    local t, encoded = _value_to_xml(v, shared_pool, shared_index)
                    local addr = build_a1(r, c)
                    local s_idx = style_for_cell and style_for_cell(r, c) or 0
                    local s_attr = s_idx > 0 and (' s="' .. s_idx .. '"') or ""
                    pieces[#pieces + 1] = string.format(
                        '<c r="%s" t="%s"%s><v>%s</v></c>',
                        addr, t, s_attr, encoded)
                end
            end
            pieces[#pieces + 1] = '</row>'
        end
    end
    pieces[#pieces + 1] = '</sheetData></worksheet>'
    return table.concat(pieces)
end

local function _build_shared_strings(pool)
    -- Build pieces incrementally so the table constructor doesn't end with
    -- a function call (CLua JIT can't lower OP_SETLIST B=0).
    local pieces = {}
    pieces[1] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    pieces[2] = string.format(
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="%d" uniqueCount="%d">',
        #pool, #pool)
    for _, s in ipairs(pool) do
        pieces[#pieces + 1] = '<si><t xml:space="preserve">' ..
            xml_escape(s) .. '</t></si>'
    end
    pieces[#pieces + 1] = '</sst>'
    return table.concat(pieces)
end

local function _build_workbook_xml(sheets)
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"',
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
        '<sheets>',
    }
    for i, s in ipairs(sheets) do
        pieces[#pieces + 1] = string.format(
            '<sheet name="%s" sheetId="%d" r:id="rId%d"/>',
            xml_escape(s._name), i, i)
    end
    pieces[#pieces + 1] = '</sheets></workbook>'
    return table.concat(pieces)
end

local function _build_workbook_rels(sheets)
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    }
    for i, _ in ipairs(sheets) do
        pieces[#pieces + 1] = string.format(
            '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>',
            i, i)
    end
    pieces[#pieces + 1] = string.format(
        '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>',
        #sheets + 1)
    pieces[#pieces + 1] = string.format(
        '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>',
        #sheets + 2)
    pieces[#pieces + 1] = '</Relationships>'
    return table.concat(pieces)
end

local function _build_root_rels()
    return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>]]
end

local function _build_content_types(sheets)
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>',
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>',
    }
    for i, _ in ipairs(sheets) do
        pieces[#pieces + 1] = string.format(
            '<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
            i)
    end
    pieces[#pieces + 1] = '</Types>'
    return table.concat(pieces)
end

local function _collect_styles(sheets)
    -- Compose number formats, fonts, fills, borders, cellXfs.
    -- Return (styles_xml, style_for_cell(sheet_idx, r, c) -> xf_index).
    local fmts = {}      -- numFmt strings -> numFmtId
    local fmt_list = {}
    local next_fmt_id = 164
    local function reg_fmt(s)
        if fmts[s] then return fmts[s] end
        fmts[s] = next_fmt_id
        fmt_list[#fmt_list + 1] = { id = next_fmt_id, code = s }
        next_fmt_id = next_fmt_id + 1
        return fmts[s]
    end
    local fonts = { { bold = false, italic = false } }  -- default font index 0
    local function reg_font(b, i)
        for idx, f in ipairs(fonts) do
            if f.bold == not not b and f.italic == not not i then return idx - 1 end
        end
        fonts[#fonts + 1] = { bold = not not b, italic = not not i }
        return #fonts - 1
    end
    -- xfs[1] is default (numFmtId=0, fontId=0).
    local xfs = { { num = 0, font = 0 } }
    local function reg_xf(num, font)
        for idx, x in ipairs(xfs) do
            if x.num == num and x.font == font then return idx - 1 end
        end
        xfs[#xfs + 1] = { num = num, font = font }
        return #xfs - 1
    end
    local sheet_lookups = {}  -- [sheet_idx] = function(r,c) -> xf_index
    for si, s in ipairs(sheets) do
        local map = {}  -- map[r][c] = xf_idx
        for _, fdef in ipairs(s._fmts or {}) do
            local o = fdef.opts
            local num = 0
            if o.number_format then num = reg_fmt(o.number_format) end
            local font = reg_font(o.bold, o.italic)
            local xf = reg_xf(num, font)
            -- Resolve range: "A1" or "A1:B3"
            local a1, a2 = fdef.range:match("^(%S+):(%S+)$")
            local r1, c1, r2, c2
            if a1 then
                r1, c1 = parse_a1(a1); r2, c2 = parse_a1(a2)
            else
                r1, c1 = parse_a1(fdef.range); r2, c2 = r1, c1
            end
            if r1 then
                for r = r1, r2 do
                    map[r] = map[r] or {}
                    for c = c1, c2 do map[r][c] = xf end
                end
            end
        end
        sheet_lookups[si] = function(r, c) return map[r] and map[r][c] or 0 end
    end
    -- Build styles.xml.
    local pieces = {
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    }
    if #fmt_list > 0 then
        pieces[#pieces + 1] = string.format('<numFmts count="%d">', #fmt_list)
        for _, f in ipairs(fmt_list) do
            pieces[#pieces + 1] = string.format(
                '<numFmt numFmtId="%d" formatCode="%s"/>', f.id, xml_escape(f.code))
        end
        pieces[#pieces + 1] = '</numFmts>'
    end
    pieces[#pieces + 1] = string.format('<fonts count="%d">', #fonts)
    for _, f in ipairs(fonts) do
        local inside = '<sz val="11"/><name val="Calibri"/>'
        if f.bold   then inside = '<b/>' .. inside end
        if f.italic then inside = '<i/>' .. inside end
        pieces[#pieces + 1] = '<font>' .. inside .. '</font>'
    end
    pieces[#pieces + 1] = '</fonts>'
    pieces[#pieces + 1] = '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
    pieces[#pieces + 1] = '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    pieces[#pieces + 1] = '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    pieces[#pieces + 1] = string.format('<cellXfs count="%d">', #xfs)
    for _, x in ipairs(xfs) do
        local apply_num = x.num > 0 and ' applyNumberFormat="1"' or ""
        local apply_font = x.font > 0 and ' applyFont="1"' or ""
        pieces[#pieces + 1] = string.format(
            '<xf numFmtId="%d" fontId="%d" fillId="0" borderId="0" xfId="0"%s%s/>',
            x.num, x.font, apply_num, apply_font)
    end
    pieces[#pieces + 1] = '</cellXfs>'
    pieces[#pieces + 1] = '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    pieces[#pieces + 1] = '</styleSheet>'
    return table.concat(pieces), sheet_lookups
end

function _wwb_mt:add_sheet(name)
    name = name or ("Sheet" .. (#self._sheets + 1))
    local sh = setmetatable({
        _name    = name,
        _cells   = {},
        _max_row = 0,
        _max_col = 0,
    }, _wsheet_mt)
    self._sheets[#self._sheets + 1] = sh
    return sh
end

function _wwb_mt:save(path)
    if #self._sheets == 0 then self:add_sheet("Sheet1") end
    local shared_pool, shared_index = {}, {}
    local styles_xml, sheet_lookups = _collect_styles(self._sheets)
    local w = zip.create(path)
    w:add_file("[Content_Types].xml", _build_content_types(self._sheets))
    w:add_file("_rels/.rels", _build_root_rels())
    w:add_file("xl/workbook.xml", _build_workbook_xml(self._sheets))
    w:add_file("xl/_rels/workbook.xml.rels", _build_workbook_rels(self._sheets))
    w:add_file("xl/styles.xml", styles_xml)
    for i, s in ipairs(self._sheets) do
        local xml_body = _build_sheet_xml(s, shared_pool, shared_index, sheet_lookups[i])
        w:add_file(string.format("xl/worksheets/sheet%d.xml", i), xml_body)
    end
    w:add_file("xl/sharedStrings.xml", _build_shared_strings(shared_pool))
    return w:close()
end

function M.create()
    return setmetatable({ _sheets = {} }, _wwb_mt)
end

return M
