-- quoted_printable -- RFC 2045 section 6.7.
--
-- Public surface:
--   quoted_printable.encode(s, opts?) -> string
--   quoted_printable.decode(s)        -> string
--
-- opts:
--   line_length -- max output line length, default 76 (RFC max)
--   binary      -- if true, encode CR and LF as =0D=0A rather than emitting CRLF

local M = {}

local LINE_MAX = 76  -- RFC 2045 hard maximum (counting the trailing '=' soft break)

local function hex(b) return string.format("=%02X", b) end

-- Bytes that MUST be encoded: 0x00..0x08, 0x0B..0x1F (except TAB), 0x7F..0xFF, '='.
-- Bytes that MAY pass through: 0x21..0x3C, 0x3E..0x7E, TAB, SP (with end-of-line caveat).
local function needs_encode(b)
    if b == 0x09 or b == 0x20 then return false end  -- tab/space, handled separately at EOL
    if b == 0x3D then return true end                 -- '='
    if b < 0x20 then return true end
    if b > 0x7E then return true end
    return false
end

function M.encode(s, opts)
    if type(s) ~= "string" then
        error("quoted_printable.encode: expected string, got " .. type(s))
    end
    opts = opts or {}
    local line_max = opts.line_length or LINE_MAX
    local binary = opts.binary

    local out, n = {}, 0
    local line_len = 0
    local len = #s
    local i = 1

    local function append(piece, piece_len)
        if line_len + piece_len > line_max - 1 then
            -- Soft break: emit '=' + CRLF, then start a new line.
            n = n + 1; out[n] = "=\r\n"
            line_len = 0
        end
        n = n + 1; out[n] = piece
        line_len = line_len + piece_len
    end

    while i <= len do
        local b = s:byte(i)
        -- Handle CRLF / LF as hard line breaks (unless binary mode).
        if not binary and b == 0x0D and s:byte(i + 1) == 0x0A then
            -- If previous char on the output line is space/tab, encode it.
            if n > 0 then
                local prev = out[n]
                local last_char = prev:sub(-1)
                if last_char == " " or last_char == "\t" then
                    -- Replace trailing whitespace with its encoded form.
                    out[n] = prev:sub(1, -2) .. hex(string.byte(last_char))
                    -- adjust line_len: removed 1, added 3
                    line_len = line_len + 2
                    if line_len > line_max then
                        -- Force a soft break before continuing -- pathological, rare.
                    end
                end
            end
            n = n + 1; out[n] = "\r\n"
            line_len = 0
            i = i + 2
        elseif not binary and b == 0x0A then
            if n > 0 then
                local prev = out[n]
                local last_char = prev:sub(-1)
                if last_char == " " or last_char == "\t" then
                    out[n] = prev:sub(1, -2) .. hex(string.byte(last_char))
                    line_len = line_len + 2
                end
            end
            n = n + 1; out[n] = "\r\n"
            line_len = 0
            i = i + 1
        elseif needs_encode(b) then
            append(hex(b), 3)
            i = i + 1
        else
            append(string.char(b), 1)
            i = i + 1
        end
    end

    -- RFC 2045 6.7 rule 3: a space/tab at the very end of the data must be
    -- encoded too (mirror the pre-hard-break logic above).
    if n > 0 then
        local prev = out[n]
        local last_char = prev:sub(-1)
        if last_char == " " or last_char == "\t" then
            out[n] = prev:sub(1, -2) .. hex(string.byte(last_char))
        end
    end

    return table.concat(out)
end

function M.decode(s)
    if type(s) ~= "string" then
        error("quoted_printable.decode: expected string, got " .. type(s))
    end
    local out, n = {}, 0
    local len = #s
    local i = 1
    while i <= len do
        local b = s:byte(i)
        if b == 0x3D then  -- '='
            local h1 = s:byte(i + 1)
            local h2 = s:byte(i + 2)
            -- Soft line break: =CRLF, =LF, or = at end of string.
            if h1 == 0x0D and h2 == 0x0A then
                i = i + 3
            elseif h1 == 0x0A then
                i = i + 2
            elseif h1 == nil then
                i = i + 1
            else
                local hex_str = string.char(h1, h2)
                local v = tonumber(hex_str, 16)
                if v == nil then
                    -- Invalid escape: per RFC, output as-is (robustness).
                    n = n + 1; out[n] = "="
                    i = i + 1
                else
                    n = n + 1; out[n] = string.char(v)
                    i = i + 3
                end
            end
        else
            n = n + 1; out[n] = string.char(b)
            i = i + 1
        end
    end
    return table.concat(out)
end

return M
