-- properties -- Java .properties file decoder / encoder.
--
-- Public surface:
--   properties.decode(text)         -> { [key] = value }
--   properties.encode(table, opts?) -> string
--
-- Decode behavior (Java spec):
--   * # or ! at the start of a line (after any leading whitespace) marks a comment.
--   * Key/value separator: =, :, or whitespace (first one wins).
--   * Backslash at end of line continues onto the next logical line.
--   * Escapes: \t, \n, \r, \f, \\, \", \', \=, \:, \ (space), \uXXXX.
--   * Trailing whitespace in value is preserved; leading whitespace stripped.
--   * Duplicate keys: later wins.
--
-- Encode options:
--   opts.sort       -- sort keys alphabetically (default true)
--   opts.separator  -- "=" (default), ":", or " "
--   opts.escape_unicode -- if true, emit \uXXXX for non-ASCII bytes (default false)

local M = {}

local sub    = string.sub
local find   = string.find
local match  = string.match
local format = string.format
local byte   = string.byte
local concat = table.concat
local gmatch = string.gmatch

-- ===== Decode ==========================================================

local function unescape(s)
    local out, n, i = {}, 0, 1
    local len = #s
    while i <= len do
        local c = sub(s, i, i)
        if c == "\\" and i < len then
            local nc = sub(s, i + 1, i + 1)
            if     nc == "t" then n = n + 1; out[n] = "\t"; i = i + 2
            elseif nc == "n" then n = n + 1; out[n] = "\n"; i = i + 2
            elseif nc == "r" then n = n + 1; out[n] = "\r"; i = i + 2
            elseif nc == "f" then n = n + 1; out[n] = "\f"; i = i + 2
            elseif nc == "\\" then n = n + 1; out[n] = "\\"; i = i + 2
            elseif nc == '"' then n = n + 1; out[n] = '"';  i = i + 2
            elseif nc == "'" then n = n + 1; out[n] = "'";  i = i + 2
            elseif nc == "=" then n = n + 1; out[n] = "=";  i = i + 2
            elseif nc == ":" then n = n + 1; out[n] = ":";  i = i + 2
            elseif nc == " " then n = n + 1; out[n] = " ";  i = i + 2
            elseif nc == "u" then
                local hex = sub(s, i + 2, i + 5)
                local cp = tonumber(hex, 16)
                if cp then
                    n = n + 1; out[n] = utf8.char(cp); i = i + 6
                else
                    n = n + 1; out[n] = nc; i = i + 2
                end
            else
                n = n + 1; out[n] = nc; i = i + 2
            end
        else
            n = n + 1; out[n] = c; i = i + 1
        end
    end
    return concat(out)
end

local function is_continuation(line)
    -- Trailing backslash with an odd run of backslashes means continuation.
    local trail = 0
    local i = #line
    while i >= 1 and sub(line, i, i) == "\\" do
        trail = trail + 1; i = i - 1
    end
    return (trail % 2) == 1
end

function M.decode(text)
    if type(text) ~= "string" then error("properties.decode: expected string") end
    if sub(text, 1, 3) == "\xEF\xBB\xBF" then text = sub(text, 4) end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local out = {}
    local logical = nil
    for raw in gmatch(text .. "\n", "([^\n]*)\n") do
        -- Strip leading whitespace.
        local line = raw:gsub("^[ \t\f]+", "")
        if logical then
            -- Continuation of prior logical line.
            logical = logical .. line
        elseif line == "" or sub(line, 1, 1) == "#" or sub(line, 1, 1) == "!" then
            -- skip
        else
            logical = line
        end
        if logical and is_continuation(logical) then
            logical = sub(logical, 1, -2)  -- strip trailing backslash
        elseif logical then
            -- Find unescaped separator.
            local i, len = 1, #logical
            local key_end, sep_end
            while i <= len do
                local c = sub(logical, i, i)
                if c == "\\" then i = i + 2
                elseif c == "=" or c == ":" then
                    key_end = i - 1
                    sep_end = i
                    -- Skip whitespace after the separator.
                    local j = i + 1
                    while j <= len and (sub(logical, j, j) == " " or sub(logical, j, j) == "\t" or sub(logical, j, j) == "\f") do
                        j = j + 1
                    end
                    sep_end = j - 1
                    break
                elseif c == " " or c == "\t" or c == "\f" then
                    key_end = i - 1
                    -- Skip whitespace; if next non-ws is = or :, those become the sep.
                    local j = i
                    while j <= len and (sub(logical, j, j) == " " or sub(logical, j, j) == "\t" or sub(logical, j, j) == "\f") do
                        j = j + 1
                    end
                    if j <= len and (sub(logical, j, j) == "=" or sub(logical, j, j) == ":") then
                        j = j + 1
                        while j <= len and (sub(logical, j, j) == " " or sub(logical, j, j) == "\t" or sub(logical, j, j) == "\f") do
                            j = j + 1
                        end
                    end
                    sep_end = j - 1
                    break
                else
                    i = i + 1
                end
            end
            if not key_end then
                -- Key with no separator -> empty string value.
                out[unescape(logical)] = ""
            else
                local key = unescape(sub(logical, 1, key_end))
                local val = unescape(sub(logical, sep_end + 1))
                out[key] = val
            end
            logical = nil
        end
    end
    return out
end

-- ===== Encode ==========================================================

local function escape_key(s)
    local out, n, i = {}, 0, 1
    while i <= #s do
        local c = sub(s, i, i); local b = byte(s, i)
        if c == "\\" or c == "=" or c == ":" or c == " " or c == "\t" or c == "\f" or c == "#" or c == "!" then
            n = n + 1; out[n] = "\\" .. c
        elseif b == 0x0A then n = n + 1; out[n] = "\\n"
        elseif b == 0x0D then n = n + 1; out[n] = "\\r"
        else
            n = n + 1; out[n] = c
        end
        i = i + 1
    end
    return concat(out)
end

local function escape_value(s, escape_unicode)
    if s == nil then return "" end
    s = tostring(s)
    local out, n, i = {}, 0, 1
    while i <= #s do
        local b = byte(s, i)
        if b == 0x5C then n = n + 1; out[n] = "\\\\"; i = i + 1
        elseif b == 0x0A then n = n + 1; out[n] = "\\n"; i = i + 1
        elseif b == 0x0D then n = n + 1; out[n] = "\\r"; i = i + 1
        elseif b == 0x09 then n = n + 1; out[n] = "\\t"; i = i + 1
        elseif b == 0x0C then n = n + 1; out[n] = "\\f"; i = i + 1
        elseif b == 0x20 and n == 0 then
            -- Leading space must be escaped.
            n = n + 1; out[n] = "\\ "; i = i + 1
        elseif escape_unicode and b >= 0x80 then
            -- Best-effort: emit the byte as \uXXXX of the raw codepoint.
            -- For full correctness we'd UTF-8 decode; we do a simple decode.
            local cp, adv
            if b < 0xC0 then
                cp = b; adv = 1
            elseif b < 0xE0 then
                cp = ((b & 0x1F) << 6) | (byte(s, i + 1) & 0x3F); adv = 2
            elseif b < 0xF0 then
                cp = ((b & 0x0F) << 12) | ((byte(s, i + 1) & 0x3F) << 6) | (byte(s, i + 2) & 0x3F); adv = 3
            else
                cp = ((b & 0x07) << 18) | ((byte(s, i + 1) & 0x3F) << 12)
                   | ((byte(s, i + 2) & 0x3F) << 6) | (byte(s, i + 3) & 0x3F); adv = 4
            end
            if cp <= 0xFFFF then
                n = n + 1; out[n] = format("\\u%04X", cp)
            else
                -- Encode as surrogate pair.
                cp = cp - 0x10000
                local hi = 0xD800 + (cp >> 10)
                local lo = 0xDC00 + (cp & 0x3FF)
                n = n + 1; out[n] = format("\\u%04X\\u%04X", hi, lo)
            end
            i = i + adv
        else
            n = n + 1; out[n] = sub(s, i, i); i = i + 1
        end
    end
    return concat(out)
end

function M.encode(t, opts)
    opts = opts or {}
    if type(t) ~= "table" then error("properties.encode: expected table") end
    local sep = opts.separator or "="
    if sep ~= "=" and sep ~= ":" and sep ~= " " then error("properties.encode: bad separator") end
    local keys, n = {}, 0
    for k in pairs(t) do n = n + 1; keys[n] = k end
    if opts.sort ~= false then
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    end
    local lines = {}
    for i, k in ipairs(keys) do
        lines[i] = escape_key(tostring(k)) .. sep .. escape_value(t[k], opts.escape_unicode)
    end
    return concat(lines, "\n") .. "\n"
end

return M
