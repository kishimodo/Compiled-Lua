-- csv -- RFC 4180 CSV encoder / decoder.
--
-- Public surface:
--   csv.decode(text, opts?)         -> { row1, row2, ... }
--   csv.encode(rows, opts?)         -> string
--   csv.reader(input_fn, opts?)     -> iterator
--   csv.writer(emit_fn, opts?)      -> { write(row), close() }
--
-- Options:
--   delimiter  (default ",")        -- field separator
--   quote      (default '"')        -- quote character
--   escape     (default '"')        -- RFC 4180 doubles the quote; some dialects use "\"
--   newline    (default "\r\n")     -- for encode output
--   headers    (decode)             -- false: rows are arrays (default)
--                                      true:  first row is treated as headers and
--                                             subsequent rows become tables keyed by header
--                                      table: explicit header list
--   skip_blank (decode, default true) -- skip lines that are empty
--   trim       (decode, default false) -- trim each field
--
-- The streaming reader pulls characters via input_fn(): each call should
-- return a string chunk or nil at EOF. The reader iterator yields one
-- row per call (an array or, with headers, a table).

local M = {}

local sub    = string.sub
local find   = string.find
local byte   = string.byte
local match  = string.match
local concat = table.concat
local rep    = string.rep

local function default_opts(opts)
    opts = opts or {}
    opts.delimiter = opts.delimiter or ","
    opts.quote     = opts.quote     or '"'
    opts.escape    = opts.escape    or opts.quote
    opts.newline   = opts.newline   or "\r\n"
    if opts.skip_blank == nil then opts.skip_blank = true end
    return opts
end

-- Internal: parse a single record starting at position `i` in `s`.
-- Returns (fields, next_pos, eof_after).
local function parse_record(s, i, opts)
    local fields, fn = {}, 0
    local len = #s
    local delim_b = byte(opts.delimiter)
    local quote_b = byte(opts.quote)
    local esc_b   = byte(opts.escape)

    while true do
        local c = byte(s, i)
        local field
        if c == quote_b then
            -- Quoted field.
            local buf, bn = {}, 0
            i = i + 1
            while i <= len do
                local cc = byte(s, i)
                if cc == quote_b then
                    if esc_b == quote_b and byte(s, i + 1) == quote_b then
                        bn = bn + 1; buf[bn] = opts.quote; i = i + 2
                    else
                        i = i + 1; break
                    end
                elseif cc == esc_b and esc_b ~= quote_b then
                    bn = bn + 1; buf[bn] = sub(s, i + 1, i + 1); i = i + 2
                else
                    bn = bn + 1; buf[bn] = sub(s, i, i); i = i + 1
                end
            end
            field = concat(buf)
        else
            -- Unquoted field: read until delimiter or newline.
            local start = i
            while i <= len do
                local cc = byte(s, i)
                if cc == delim_b or cc == 0x0A or cc == 0x0D then break end
                i = i + 1
            end
            field = sub(s, start, i - 1)
        end
        if opts.trim then field = (field:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")) end
        fn = fn + 1; fields[fn] = field

        local nc = byte(s, i)
        if nc == delim_b then
            i = i + 1
        elseif nc == 0x0D then
            i = i + 1
            if byte(s, i) == 0x0A then i = i + 1 end
            return fields, i, i > len
        elseif nc == 0x0A then
            return fields, i + 1, i + 1 > len
        elseif i > len then
            return fields, i, true
        end
    end
end

function M.decode(text, opts)
    opts = default_opts(opts)
    if type(text) ~= "string" then error("csv.decode: expected string") end
    if sub(text, 1, 3) == "\xEF\xBB\xBF" then text = sub(text, 4) end
    local rows, rn = {}, 0
    local i, len = 1, #text
    while i <= len do
        local fields, np = parse_record(text, i, opts)
        i = np
        if not (opts.skip_blank and #fields == 1 and fields[1] == "") then
            rn = rn + 1; rows[rn] = fields
        end
    end
    if opts.headers then
        local headers
        if type(opts.headers) == "table" then
            headers = opts.headers
        else
            headers = rows[1]
            table.remove(rows, 1); rn = rn - 1
        end
        for ri = 1, rn do
            local r = rows[ri]
            local mapped = {}
            for hi, h in ipairs(headers) do mapped[h] = r[hi] end
            rows[ri] = mapped
        end
    end
    return rows
end

function M.reader(input_fn, opts)
    opts = default_opts(opts)
    local buf, p = "", 1
    local eof = false
    local function pump()
        local chunk = input_fn()
        if chunk == nil then eof = true; return end
        buf = sub(buf, p) .. chunk
        p = 1
    end
    local headers
    if opts.headers and type(opts.headers) == "table" then
        headers = opts.headers
    end
    local first = true

    return function()
        while true do
            -- Ensure enough data; pump until EOF or a newline appears past p.
            local nl = find(buf, "[\r\n]", p)
            -- If a record is quoted, we may need more data than a single newline.
            -- Strategy: try parse, if it crosses end-of-buf without termination, pump more.
            if not nl and not eof then pump() end
            if p > #buf then
                if eof then return nil end
                pump(); if p > #buf and eof then return nil end
            end
            -- Try a tentative parse with whatever is in buffer; if we ran out before terminating, pump.
            local saved_buf, saved_p = buf, p
            local ok, fields, np = pcall(parse_record, buf, p, opts)
            if not ok then
                if eof then error(fields) end
                pump(); buf = saved_buf .. ""; p = saved_p
            else
                p = np
                if opts.skip_blank and #fields == 1 and fields[1] == "" then
                    -- skip
                else
                    if first and opts.headers and not headers then
                        headers = fields
                        first = false
                    else
                        first = false
                        if headers then
                            local mapped = {}
                            for hi, h in ipairs(headers) do mapped[h] = fields[hi] end
                            return mapped
                        end
                        return fields
                    end
                end
                if p > #buf and not eof then pump() end
                if p > #buf and eof then return nil end
            end
        end
    end
end

-- ===== Encode ==========================================================

local function escape_field(field, opts)
    local s = tostring(field)
    local q = opts.quote
    if find(s, opts.delimiter, 1, true) or find(s, q, 1, true)
    or find(s, "\n", 1, true) or find(s, "\r", 1, true) then
        if opts.escape == q then
            s = s:gsub(q, q .. q)
        else
            s = s:gsub(opts.escape, opts.escape .. opts.escape)
            s = s:gsub(q, opts.escape .. q)
        end
        return q .. s .. q
    end
    return s
end

local function encode_row(row, opts)
    local parts, n = {}, 0
    for i = 1, #row do n = n + 1; parts[n] = escape_field(row[i], opts) end
    return concat(parts, opts.delimiter)
end

function M.encode(rows, opts)
    opts = default_opts(opts)
    if type(rows) ~= "table" then error("csv.encode: expected table") end
    local out, n = {}, 0
    -- If first row is a table-with-string-keys, treat all rows as such and emit headers.
    local first = rows[1]
    if type(first) == "table" and next(first) ~= nil
       and type(next(first)) ~= "number" then
        local headers, hn = {}, 0
        if opts.headers and type(opts.headers) == "table" then
            headers = opts.headers
            hn = #headers
        else
            for k in pairs(first) do hn = hn + 1; headers[hn] = k end
            table.sort(headers)
        end
        n = n + 1; out[n] = encode_row(headers, opts)
        for ri = 1, #rows do
            local r, arr = rows[ri], {}
            for hi = 1, hn do arr[hi] = r[headers[hi]] end
            n = n + 1; out[n] = encode_row(arr, opts)
        end
    else
        for ri = 1, #rows do
            n = n + 1; out[n] = encode_row(rows[ri], opts)
        end
    end
    return concat(out, opts.newline) .. opts.newline
end

function M.writer(emit_fn, opts)
    opts = default_opts(opts)
    local w = {}
    function w.write(row) emit_fn(encode_row(row, opts) .. opts.newline) end
    function w.close() end
    return w
end

return M
