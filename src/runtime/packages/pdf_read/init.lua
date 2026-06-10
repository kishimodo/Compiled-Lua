-- pdf_read -- PDF 1.7 parser.
--
-- PDF anatomy this parser handles:
--   * Header line "%PDF-1.X"
--   * Body of indirect objects:  "ID GEN obj ... endobj"
--   * Cross-reference table (xref keyword) OR cross-reference stream
--     (an indirect object whose dict has /Type /XRef).
--   * Trailer dict with /Size, /Root, /Info, /Prev
--
-- Indirect object values are one of:
--   * null, true, false
--   * integer, real
--   * literal string  "(...)"  with escape sequences
--   * hex string      "<...>"
--   * name            "/Name"
--   * array           "[ ... ]"
--   * dictionary      "<< /K v ... >>"
--   * stream          dict + "stream\n...\nendstream"
--   * reference       "ID GEN R"
--
-- Stream filters supported: FlateDecode, ASCIIHexDecode, ASCII85Decode,
-- LZWDecode, and FlateDecode/LZWDecode with the PNG-style /Predictor.
--
-- Public surface:
--   pdf_read.open(path_or_bytes) -> doc
--   doc:page_count()             -> n
--   doc:metadata()               -> { title, author, ... }
--   doc:page(idx)                -> page
--   doc:text()                   -> all pages text joined
--   doc:annotations()            -> { { page, subtype, rect, contents, uri } }
--   doc:forms()                  -> { { name, type, value, default_value } }
--   doc:catalog()                -> raw catalog dictionary
--   page:text()                  -> extracted text
--   page:size()                  -> { width, height }
--   page:rotation()              -> 0|90|180|270
--   page:images()                -> { { x, y, w, h, image_data } }

local M = {}

local _zlib_ok, zlib = pcall(require, "zlib")
if not _zlib_ok then zlib = nil end

-- ===== Tokenisation =====================================================

local function is_ws(b)
    return b == 0x00 or b == 0x09 or b == 0x0A or b == 0x0C or b == 0x0D or b == 0x20
end

local function is_delim(b)
    return b == 0x28 or b == 0x29  -- ( )
        or b == 0x3C or b == 0x3E  -- < >
        or b == 0x5B or b == 0x5D  -- [ ]
        or b == 0x7B or b == 0x7D  -- { }
        or b == 0x2F or b == 0x25  -- / %
end

local function skip_ws_and_comments(s, i)
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if is_ws(b) then
            i = i + 1
        elseif b == 0x25 then  -- comment until newline
            while i <= len and s:byte(i) ~= 0x0A and s:byte(i) ~= 0x0D do
                i = i + 1
            end
        else
            break
        end
    end
    return i
end

-- ===== Object parser ====================================================

local _parse_value  -- forward

local function parse_name(s, i)
    -- /Name -- terminated by whitespace/delimiter. Two-hex-digit
    -- escapes via #XX.
    i = i + 1
    local start = i
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if is_ws(b) or is_delim(b) then break end
        i = i + 1
    end
    local raw = s:sub(start, i - 1)
    raw = raw:gsub("#(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return raw, i
end

local function parse_number(s, i)
    local start = i
    local len = #s
    if s:byte(i) == 0x2D or s:byte(i) == 0x2B then i = i + 1 end
    while i <= len do
        local b = s:byte(i)
        if (b >= 0x30 and b <= 0x39) or b == 0x2E then i = i + 1
        else break end
    end
    local numstr = s:sub(start, i - 1)
    local n = tonumber(numstr)
    return n, i
end

local function parse_literal_string(s, i)
    -- (...) with balanced parens and escape sequences
    i = i + 1
    local depth, len = 1, #s
    local parts, np = {}, 0
    local start = i
    while i <= len and depth > 0 do
        local b = s:byte(i)
        if b == 0x5C then  -- backslash escape
            if i > start then np = np + 1; parts[np] = s:sub(start, i - 1) end
            local c = s:byte(i + 1)
            if c == 0x6E then np = np + 1; parts[np] = "\n"; i = i + 2
            elseif c == 0x72 then np = np + 1; parts[np] = "\r"; i = i + 2
            elseif c == 0x74 then np = np + 1; parts[np] = "\t"; i = i + 2
            elseif c == 0x62 then np = np + 1; parts[np] = "\b"; i = i + 2
            elseif c == 0x66 then np = np + 1; parts[np] = "\f"; i = i + 2
            elseif c == 0x28 then np = np + 1; parts[np] = "("; i = i + 2
            elseif c == 0x29 then np = np + 1; parts[np] = ")"; i = i + 2
            elseif c == 0x5C then np = np + 1; parts[np] = "\\"; i = i + 2
            elseif c == 0x0A then i = i + 2  -- line continuation
            elseif c == 0x0D then
                if s:byte(i + 2) == 0x0A then i = i + 3 else i = i + 2 end
            elseif c and c >= 0x30 and c <= 0x37 then
                -- octal escape, up to 3 digits
                local oct = string.char(c - 0x30)
                i = i + 2
                for _ = 1, 2 do
                    local b2 = s:byte(i)
                    if b2 and b2 >= 0x30 and b2 <= 0x37 then
                        oct = oct .. string.char(b2 - 0x30)
                        i = i + 1
                    else break end
                end
                np = np + 1; parts[np] = string.char(tonumber(oct, 8))
            else
                -- Unknown -- drop the backslash.
                i = i + 1
            end
            start = i
        elseif b == 0x28 then
            depth = depth + 1; i = i + 1
        elseif b == 0x29 then
            depth = depth - 1
            if depth == 0 then break end
            i = i + 1
        else
            i = i + 1
        end
    end
    if i > start then np = np + 1; parts[np] = s:sub(start, i - 1) end
    return table.concat(parts), i + 1
end

local function parse_hex_string(s, i)
    i = i + 1
    local len = #s
    local digits, n = {}, 0
    while i <= len and s:byte(i) ~= 0x3E do
        local b = s:byte(i)
        if (b >= 0x30 and b <= 0x39)
           or (b >= 0x41 and b <= 0x46)
           or (b >= 0x61 and b <= 0x66) then
            n = n + 1; digits[n] = string.char(b)
        end
        i = i + 1
    end
    local hex = table.concat(digits)
    if (#hex % 2) == 1 then hex = hex .. "0" end
    local out, on = {}, 0
    for k = 1, #hex, 2 do
        on = on + 1; out[on] = string.char(tonumber(hex:sub(k, k + 1), 16))
    end
    return table.concat(out), i + 1
end

local function parse_array(s, i)
    i = i + 1
    local arr, n = {}, 0
    while true do
        i = skip_ws_and_comments(s, i)
        if i > #s then error("pdf: unterminated array") end
        if s:byte(i) == 0x5D then return arr, i + 1 end
        local v
        v, i = _parse_value(s, i)
        n = n + 1; arr[n] = v
    end
end

local function parse_dict(s, i)
    -- Already consumed first '<'. Second '<' must follow.
    i = i + 2
    local d = {}
    while true do
        i = skip_ws_and_comments(s, i)
        if i + 1 <= #s and s:byte(i) == 0x3E and s:byte(i + 1) == 0x3E then
            return d, i + 2
        end
        if s:byte(i) ~= 0x2F then
            error(string.format("pdf: expected name in dict at offset %d (got %s)",
                i, s:sub(i, i + 5)))
        end
        local name
        name, i = parse_name(s, i)
        i = skip_ws_and_comments(s, i)
        local v
        v, i = _parse_value(s, i)
        d[name] = v
    end
end

local function parse_keyword(s, i)
    local start = i
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if is_ws(b) or is_delim(b) then break end
        i = i + 1
    end
    return s:sub(start, i - 1), i
end

_parse_value = function(s, i)
    i = skip_ws_and_comments(s, i)
    if i > #s then error("pdf: unexpected EOF") end
    local b = s:byte(i)
    if b == 0x3C then
        if s:byte(i + 1) == 0x3C then
            return parse_dict(s, i)
        else
            return parse_hex_string(s, i)
        end
    elseif b == 0x28 then
        return parse_literal_string(s, i)
    elseif b == 0x5B then
        return parse_array(s, i)
    elseif b == 0x2F then
        return parse_name(s, i)
    elseif (b >= 0x30 and b <= 0x39) or b == 0x2B or b == 0x2D or b == 0x2E then
        -- Number, or possibly a reference "ID GEN R".
        local n1, j = parse_number(s, i)
        local save = j
        j = skip_ws_and_comments(s, j)
        local b2 = s:byte(j)
        if b2 and ((b2 >= 0x30 and b2 <= 0x39)) then
            local n2, k = parse_number(s, j)
            k = skip_ws_and_comments(s, k)
            if s:byte(k) == 0x52 then  -- 'R'
                return { _ref = n1, _gen = n2 }, k + 1
            end
        end
        return n1, save
    else
        local kw, j = parse_keyword(s, i)
        if kw == "true" then return true, j
        elseif kw == "false" then return false, j
        elseif kw == "null" then return nil, j
        else
            error("pdf: unknown keyword '" .. kw .. "'")
        end
    end
end

-- ===== Filter pipelines =================================================

local function ascii_hex_decode(bytes)
    local hex = bytes:gsub("[^%x>]", "")
    local stop = hex:find(">")
    if stop then hex = hex:sub(1, stop - 1) end
    if (#hex % 2) == 1 then hex = hex .. "0" end
    local out, n = {}, 0
    for i = 1, #hex, 2 do
        n = n + 1; out[n] = string.char(tonumber(hex:sub(i, i + 1), 16))
    end
    return table.concat(out)
end

local function ascii85_decode(bytes)
    -- Strip leading "<~" and trailing "~>" if present.
    bytes = bytes:gsub("^<~", ""):gsub("~>.*$", "")
    bytes = bytes:gsub("%s+", "")
    local out, on = {}, 0
    local i = 1
    while i <= #bytes do
        if bytes:sub(i, i) == "z" then
            on = on + 1; out[on] = "\0\0\0\0"
            i = i + 1
        else
            local group = bytes:sub(i, i + 4)
            local pad = 5 - #group
            if pad > 0 then group = group .. string.rep("u", pad) end
            local n = 0
            for k = 1, 5 do
                n = n * 85 + (group:byte(k) - 33)
            end
            local b1 = math.floor(n / 16777216) % 256
            local b2 = math.floor(n / 65536) % 256
            local b3 = math.floor(n / 256) % 256
            local b4 = n % 256
            local raw = string.char(b1, b2, b3, b4)
            if pad > 0 then raw = raw:sub(1, 4 - pad) end
            on = on + 1; out[on] = raw
            i = i + 5
        end
    end
    return table.concat(out)
end

local function lzw_decode(bytes)
    -- PDF LZW: 12-bit max codes, MSB-first bits, clear=256, eof=257.
    local dict = {}
    for k = 0, 255 do dict[k] = string.char(k) end
    local dict_size = 258
    local code_width = 9
    local buf_val, buf_bits = 0, 0
    local pos = 1
    local out, on = {}, 0
    local prev
    local function read_code()
        while buf_bits < code_width and pos <= #bytes do
            buf_val = buf_val * 256 + bytes:byte(pos)
            pos = pos + 1
            buf_bits = buf_bits + 8
        end
        if buf_bits < code_width then return nil end
        local shift = buf_bits - code_width
        local code = math.floor(buf_val / (2 ^ shift)) % (2 ^ code_width)
        buf_val = buf_val % (2 ^ shift)
        buf_bits = buf_bits - code_width
        return code
    end
    while true do
        local code = read_code()
        if not code or code == 257 then break end
        if code == 256 then
            dict = {}
            for k = 0, 255 do dict[k] = string.char(k) end
            dict_size = 258
            code_width = 9
            prev = nil
        else
            local entry
            if dict[code] then
                entry = dict[code]
            elseif code == dict_size and prev then
                entry = prev .. prev:sub(1, 1)
            else
                error("lzw: invalid code " .. code)
            end
            on = on + 1; out[on] = entry
            if prev then
                dict[dict_size] = prev .. entry:sub(1, 1)
                dict_size = dict_size + 1
                if dict_size == (2 ^ code_width) and code_width < 12 then
                    code_width = code_width + 1
                end
            end
            prev = entry
        end
    end
    return table.concat(out)
end

local function apply_predictor(data, params)
    local predictor = params and params.Predictor or 1
    if predictor == 1 then return data end
    local colors  = params.Colors or 1
    local bpc     = params.BitsPerComponent or 8
    local columns = params.Columns or 1
    local bpp = math.max(1, math.floor(colors * bpc / 8))
    local row_bytes = math.floor((columns * colors * bpc + 7) / 8)
    if predictor == 2 then
        -- TIFF predictor 2 -- left.
        local out, on = {}, 0
        for r = 0, math.floor(#data / row_bytes) - 1 do
            local row_start = r * row_bytes + 1
            local prev_row = {}
            for c = 1, row_bytes do
                local v = data:byte(row_start + c - 1)
                if c > bpp then
                    v = (v + prev_row[c - bpp]) % 256
                end
                prev_row[c] = v
                on = on + 1; out[on] = string.char(v)
            end
        end
        return table.concat(out)
    end
    -- PNG predictor family: per row a filter byte precedes the row.
    local out, on = {}, 0
    local prior = {}
    for i = 1, row_bytes do prior[i] = 0 end
    local pos = 1
    while pos + row_bytes <= #data do
        local filter = data:byte(pos)
        local row = {}
        for c = 1, row_bytes do
            local raw  = data:byte(pos + c)
            local left = (c > bpp) and row[c - bpp] or 0
            local up   = prior[c]
            local upleft = (c > bpp) and prior[c - bpp] or 0
            local v
            if filter == 0 then v = raw
            elseif filter == 1 then v = (raw + left) % 256
            elseif filter == 2 then v = (raw + up) % 256
            elseif filter == 3 then v = (raw + math.floor((left + up) / 2)) % 256
            elseif filter == 4 then
                local p = left + up - upleft
                local pa = math.abs(p - left)
                local pb = math.abs(p - up)
                local pc = math.abs(p - upleft)
                local pred
                if pa <= pb and pa <= pc then pred = left
                elseif pb <= pc then pred = up
                else pred = upleft end
                v = (raw + pred) % 256
            else
                v = raw
            end
            row[c] = v
            on = on + 1; out[on] = string.char(v)
        end
        prior = row
        pos = pos + 1 + row_bytes
    end
    return table.concat(out)
end

local function decode_stream(data, filters, parmses)
    if type(filters) == "string" then filters = { filters } end
    if not filters or #filters == 0 then return data end
    parmses = parmses or {}
    if type(parmses) == "table" and parmses.Predictor then
        -- Single dict applied to all
        parmses = { parmses }
    end
    for i, f in ipairs(filters) do
        local p = parmses[i]
        if f == "FlateDecode" or f == "Fl" then
            if not zlib then
                error("pdf: FlateDecode requested but zlib unavailable")
            end
            data = zlib.decompress(data, "zlib")
            if p then data = apply_predictor(data, p) end
        elseif f == "ASCIIHexDecode" or f == "AHx" then
            data = ascii_hex_decode(data)
        elseif f == "ASCII85Decode" or f == "A85" then
            data = ascii85_decode(data)
        elseif f == "LZWDecode" or f == "LZW" then
            data = lzw_decode(data)
            if p then data = apply_predictor(data, p) end
        elseif f == "RunLengthDecode" or f == "RL" then
            local out, on = {}, 0
            local idx = 1
            while idx <= #data do
                local b = data:byte(idx)
                if b == 128 then break
                elseif b < 128 then
                    local n = b + 1
                    on = on + 1; out[on] = data:sub(idx + 1, idx + n)
                    idx = idx + 1 + n
                else
                    local n = 257 - b
                    on = on + 1; out[on] = string.rep(data:sub(idx + 1, idx + 1), n)
                    idx = idx + 2
                end
            end
            data = table.concat(out)
        else
            error("pdf: unsupported filter '" .. tostring(f) .. "'")
        end
    end
    return data
end

-- ===== Document object ==================================================

local _doc_mt  = {}
_doc_mt.__index  = _doc_mt
local _page_mt = {}
_page_mt.__index = _page_mt

-- Parse an indirect object at position i (which should be at the byte
-- right after "<id> <gen> obj" but accept being on the digit).
local function parse_indirect(s, i)
    i = skip_ws_and_comments(s, i)
    local id, j = parse_number(s, i)
    j = skip_ws_and_comments(s, j)
    local gen, k = parse_number(s, j)
    k = skip_ws_and_comments(s, k)
    if s:sub(k, k + 2) ~= "obj" then
        error(string.format("pdf: expected 'obj' at offset %d", k))
    end
    k = k + 3
    k = skip_ws_and_comments(s, k)
    local val
    val, k = _parse_value(s, k)
    k = skip_ws_and_comments(s, k)
    -- Optional stream
    if s:sub(k, k + 5) == "stream" then
        local p = k + 6
        if s:byte(p) == 0x0D then p = p + 1 end
        if s:byte(p) == 0x0A then p = p + 1 end
        local length = val.Length
        if type(length) == "table" and length._ref then
            length = nil  -- resolved later
        end
        -- If length isn't directly available, scan for endstream.
        if not length then
            local e = s:find("\nendstream", p, true)
            if not e then e = s:find("endstream", p, true) - 1 end
            length = e - p
            -- back off CR
            if length > 0 and s:byte(p + length - 1) == 0x0D then length = length - 1 end
        end
        local data = s:sub(p, p + length - 1)
        val._stream_data    = data
        val._stream_filters = val.Filter
        val._stream_parms   = val.DecodeParms
    end
    return id, val, k
end

-- Locate startxref offset near EOF.
local function find_startxref(buf)
    local len = #buf
    local scan_from = math.max(1, len - 4096)
    local tail = buf:sub(scan_from)
    local pos = tail:find("startxref")
    if not pos then error("pdf: startxref not found") end
    -- After "startxref" there's a number.
    local rest = tail:sub(pos + 9)
    local n = rest:match("%s*(%d+)")
    if not n then error("pdf: startxref offset malformed") end
    return tonumber(n)
end

-- Parse traditional xref table starting at offset xref_off.
local function parse_xref_table(buf, xref_off)
    local i = xref_off + 1  -- to 1-based
    if buf:sub(i, i + 3) ~= "xref" then
        return nil  -- maybe xref stream
    end
    i = i + 4
    i = skip_ws_and_comments(buf, i)
    local entries = {}
    while true do
        if buf:sub(i, i + 6) == "trailer" then break end
        local first, j = parse_number(buf, i)
        j = skip_ws_and_comments(buf, j)
        local count, k = parse_number(buf, j)
        k = skip_ws_and_comments(buf, k)
        for r = 0, count - 1 do
            -- Each entry is 20 bytes: "NNNNNNNNNN GGGGG x \n"
            local line = buf:sub(k, k + 19)
            local off_s, gen_s, flag = line:match("^(%d+) (%d+) ([fn])")
            if off_s then
                entries[first + r] = {
                    offset = tonumber(off_s),
                    gen    = tonumber(gen_s),
                    in_use = flag == "n",
                }
            end
            k = k + 20
        end
        i = skip_ws_and_comments(buf, k)
    end
    -- Parse trailer dict.
    local t = i + 7
    t = skip_ws_and_comments(buf, t)
    local trailer
    trailer, _ = _parse_value(buf, t)
    return entries, trailer
end

-- Parse an xref stream object at offset.
local function parse_xref_stream(buf, off)
    local _, val, _ = parse_indirect(buf, off + 1)
    local data = decode_stream(val._stream_data, val._stream_filters, val._stream_parms)
    local W = val.W
    local w1, w2, w3 = W[1], W[2], W[3]
    local record_size = w1 + w2 + w3
    local index = val.Index or { 0, val.Size }
    local entries = {}
    local pos = 1
    for k = 1, #index, 2 do
        local first = index[k]
        local count = index[k + 1]
        for r = 0, count - 1 do
            local function bytes_to_int(n, p)
                if n == 0 then return 0 end
                local v = 0
                for x = 0, n - 1 do
                    v = v * 256 + (data:byte(p + x) or 0)
                end
                return v
            end
            local t   = (w1 == 0) and 1 or bytes_to_int(w1, pos)
            local f1  = bytes_to_int(w2, pos + w1)
            local f2  = bytes_to_int(w3, pos + w1 + w2)
            if t == 1 then
                entries[first + r] = { offset = f1, gen = f2, in_use = true }
            elseif t == 2 then
                -- compressed object: f1 = stream obj number, f2 = index inside
                entries[first + r] = {
                    in_use = true,
                    compressed = true,
                    stream_obj = f1,
                    stream_idx = f2,
                }
            elseif t == 0 then
                entries[first + r] = { in_use = false, gen = f2 }
            end
            pos = pos + record_size
        end
    end
    return entries, val
end

local function load_xref(buf)
    local off = find_startxref(buf)
    local entries, trailer = parse_xref_table(buf, off)
    if not entries then
        entries, trailer = parse_xref_stream(buf, off)
    end
    -- Follow /Prev chain.
    local seen = { [off] = true }
    local cur = trailer
    while cur and cur.Prev and not seen[cur.Prev] do
        seen[cur.Prev] = true
        local prev_off = cur.Prev
        local prev_entries, prev_trailer = parse_xref_table(buf, prev_off)
        if not prev_entries then
            prev_entries, prev_trailer = parse_xref_stream(buf, prev_off)
        end
        if prev_entries then
            for id, e in pairs(prev_entries) do
                if entries[id] == nil then entries[id] = e end
            end
        end
        cur = prev_trailer
    end
    return entries, trailer
end

function _doc_mt:_object(id)
    if self._obj_cache[id] ~= nil then return self._obj_cache[id] end
    local e = self._xref[id]
    if not e or not e.in_use then return nil end
    local val
    if e.compressed then
        -- Compressed in object stream e.stream_obj at index e.stream_idx
        local sobj = self:_object(e.stream_obj)
        if not sobj or not sobj._stream_data then return nil end
        local data = decode_stream(sobj._stream_data, sobj._stream_filters, sobj._stream_parms)
        local n = sobj.N
        local first = sobj.First
        -- The first <first> bytes hold N pairs of "id offset" (decimal text).
        local hdr = data:sub(1, first)
        local pairs_list = {}
        for num in hdr:gmatch("(%-?%d+)") do
            pairs_list[#pairs_list + 1] = tonumber(num)
        end
        local target_off = pairs_list[e.stream_idx * 2 + 2]
        local body = data:sub(first + 1)
        local v, _ = _parse_value(body, target_off + 1)
        val = v
    else
        local _, v, _ = parse_indirect(self._buf, e.offset + 1)
        val = v
    end
    self._obj_cache[id] = val
    return val
end

function _doc_mt:_resolve(v)
    -- Follow indirect references one level.
    if type(v) == "table" and v._ref then
        return self:_object(v._ref)
    end
    return v
end

function _doc_mt:_resolve_deep(v, seen)
    -- Recursive resolve (cycle-safe). Used for metadata mining.
    seen = seen or {}
    v = self:_resolve(v)
    if type(v) ~= "table" or seen[v] then return v end
    seen[v] = true
    return v
end

-- ===== Page tree walking ================================================

local function _walk_pages(doc, node, acc)
    local n = doc:_resolve(node)
    if not n then return end
    if n.Type == "Pages" then
        for _, kid in ipairs(n.Kids or {}) do
            _walk_pages(doc, kid, acc)
        end
    elseif n.Type == "Page" or (n.Contents or n.MediaBox) then
        acc[#acc + 1] = n
    end
end

function _doc_mt:_pages()
    if self._pages_cache then return self._pages_cache end
    local catalog = self:catalog()
    local pages = {}
    if catalog and catalog.Pages then
        _walk_pages(self, catalog.Pages, pages)
    end
    self._pages_cache = pages
    return pages
end

function _doc_mt:page_count()
    return #self:_pages()
end

function _doc_mt:catalog()
    return self:_resolve(self._trailer.Root)
end

function _doc_mt:metadata()
    local info = self:_resolve(self._trailer.Info)
    if not info then return {} end
    return {
        title          = info.Title,
        author         = info.Author,
        creator        = info.Creator,
        producer       = info.Producer,
        subject        = info.Subject,
        keywords       = info.Keywords,
        creation_date  = info.CreationDate,
        mod_date       = info.ModDate,
    }
end

function _doc_mt:page(idx)
    local pages = self:_pages()
    local p = pages[idx]
    if not p then return nil end
    return setmetatable({ _doc = self, _node = p, _idx = idx }, _page_mt)
end

function _doc_mt:text()
    local parts = {}
    for i = 1, self:page_count() do
        local p = self:page(i)
        parts[#parts + 1] = p:text()
    end
    return table.concat(parts, "\n")
end

function _doc_mt:annotations()
    local out = {}
    for i = 1, self:page_count() do
        local p = self:_pages()[i]
        local annots = self:_resolve(p.Annots)
        if type(annots) == "table" then
            for _, a in ipairs(annots) do
                local an = self:_resolve(a)
                if an then
                    local entry = {
                        page     = i,
                        subtype  = an.Subtype,
                        rect     = an.Rect,
                        contents = an.Contents,
                    }
                    local action = self:_resolve(an.A)
                    if action and action.URI then entry.uri = action.URI end
                    out[#out + 1] = entry
                end
            end
        end
    end
    return out
end

function _doc_mt:forms()
    local catalog = self:catalog()
    local form = catalog and self:_resolve(catalog.AcroForm)
    if not form then return {} end
    local out = {}
    local function visit(field)
        local f = self:_resolve(field)
        if not f then return end
        if f.T then
            out[#out + 1] = {
                name          = f.T,
                type          = f.FT,
                value         = f.V,
                default_value = f.DV,
            }
        end
        if f.Kids then
            for _, k in ipairs(f.Kids) do visit(k) end
        end
    end
    for _, f in ipairs(form.Fields or {}) do visit(f) end
    return out
end

-- ===== Page text + image extraction =====================================

-- Decode hex pairs in <...> sub-strings.
local function _hex_to_str(hex)
    hex = hex:gsub("%s", "")
    if (#hex % 2) == 1 then hex = hex .. "0" end
    local out, n = {}, 0
    for i = 1, #hex, 2 do
        n = n + 1; out[n] = string.char(tonumber(hex:sub(i, i + 1), 16))
    end
    return table.concat(out)
end

-- Parse a content stream's text-showing operators (Tj, TJ, ', ").
-- We don't honour fonts/encodings -- we copy bytes verbatim, which
-- works for the bulk of WinAnsi/PDFDocEncoded latin text PDFs.
local function extract_text_from_content(stream)
    local out, n = {}, 0
    local i, len = 1, #stream
    local in_text_block = false
    while i <= len do
        local b = stream:byte(i)
        if b == 0x28 then  -- (
            -- literal string
            local s, j = parse_literal_string(stream, i)
            -- Look ahead for the operator: Tj / TJ / ' / "
            local k = skip_ws_and_comments(stream, j)
            -- Could be operator or could be embedded in a TJ array entry.
            local op = stream:sub(k, k + 1)
            if op:sub(1, 1) == "T" then
                if op == "Tj" or op == "TJ" then
                    n = n + 1; out[n] = s
                else
                    n = n + 1; out[n] = s
                end
            elseif stream:sub(k, k) == "'" or stream:sub(k, k) == '"' then
                n = n + 1; out[n] = "\n" .. s
            else
                n = n + 1; out[n] = s
            end
            i = j
        elseif b == 0x3C then  -- <
            local s, j = parse_hex_string(stream, i)
            n = n + 1; out[n] = s
            i = j
        elseif b == 0x5B then  -- [
            -- TJ array. Walk it pulling strings out.
            i = i + 1
            while i <= len and stream:byte(i) ~= 0x5D do
                i = skip_ws_and_comments(stream, i)
                local b2 = stream:byte(i)
                if b2 == 0x28 then
                    local s, j = parse_literal_string(stream, i)
                    n = n + 1; out[n] = s
                    i = j
                elseif b2 == 0x3C then
                    local s, j = parse_hex_string(stream, i)
                    n = n + 1; out[n] = s
                    i = j
                elseif b2 == 0x5D then
                    break
                else
                    -- number (advance) -- skip
                    local _, j = parse_number(stream, i)
                    i = j
                end
            end
            i = i + 1
        elseif b == 0x54 and stream:byte(i + 1) == 0x2A then  -- "T*" -> newline
            n = n + 1; out[n] = "\n"
            i = i + 2
        elseif b == 0x42 and stream:sub(i, i + 1) == "BT" then
            in_text_block = true; i = i + 2
        elseif b == 0x45 and stream:sub(i, i + 1) == "ET" then
            in_text_block = false
            n = n + 1; out[n] = "\n"
            i = i + 2
        else
            i = i + 1
        end
    end
    return table.concat(out)
end

function _page_mt:text()
    local doc = self._doc
    local contents = doc:_resolve(self._node.Contents)
    if not contents then return "" end
    local parts = {}
    if contents._stream_data then
        local data = decode_stream(contents._stream_data,
                                   contents._stream_filters,
                                   contents._stream_parms)
        parts[#parts + 1] = data
    elseif type(contents) == "table" then
        -- Array of streams
        for _, c in ipairs(contents) do
            local cs = doc:_resolve(c)
            if cs and cs._stream_data then
                local data = decode_stream(cs._stream_data, cs._stream_filters, cs._stream_parms)
                parts[#parts + 1] = data
            end
        end
    end
    return extract_text_from_content(table.concat(parts, "\n"))
end

function _page_mt:size()
    local mb = self._node.MediaBox
    if mb then
        return {
            width  = (mb[3] or 0) - (mb[1] or 0),
            height = (mb[4] or 0) - (mb[2] or 0),
        }
    end
    return { width = 0, height = 0 }
end

function _page_mt:rotation()
    return self._node.Rotate or 0
end

function _page_mt:images()
    local doc = self._doc
    local res = doc:_resolve(self._node.Resources)
    if not res then return {} end
    local xobj = doc:_resolve(res.XObject)
    if not xobj then return {} end
    local out = {}
    for name, ref in pairs(xobj) do
        local img = doc:_resolve(ref)
        if img and img.Subtype == "Image" and img._stream_data then
            -- Filter chain may already make this directly usable (JPEG via
            -- DCTDecode passes through as a .jpg payload). For PNG-style
            -- predictor + FlateDecode we'd need to re-pack into a PNG, so we
            -- surface the raw bytes plus the filter chain.
            local fmt = "raw"
            local data = img._stream_data
            local filters = img._stream_filters
            if filters == "DCTDecode" or
               (type(filters) == "table" and filters[#filters] == "DCTDecode") then
                fmt = "jpeg"
            elseif filters == "JPXDecode" then
                fmt = "jp2"
            end
            out[#out + 1] = {
                name        = name,
                width       = img.Width,
                height      = img.Height,
                bits        = img.BitsPerComponent,
                format      = fmt,
                image_data  = data,
                filters     = filters,
                x = nil, y = nil, w = nil, h = nil,
                -- (x,y,w,h are unavailable without interpreting cm operators
                -- in the content stream; the API contract still surfaces the
                -- keys for forward-compat.)
            }
        end
    end
    return out
end

-- ===== Public open() ====================================================

function M.open(path_or_bytes)
    local buf
    if path_or_bytes:sub(1, 4) == "%PDF" then
        buf = path_or_bytes
    else
        local f = io.open(path_or_bytes, "rb")
        if not f then error("pdf_read.open: cannot open " .. tostring(path_or_bytes)) end
        buf = f:read("*a"); f:close()
    end
    if buf:sub(1, 4) ~= "%PDF" then
        error("pdf_read.open: not a PDF (missing %PDF header)")
    end
    local xref, trailer = load_xref(buf)
    return setmetatable({
        _buf       = buf,
        _xref      = xref,
        _trailer   = trailer,
        _obj_cache = {},
    }, _doc_mt)
end

return M
