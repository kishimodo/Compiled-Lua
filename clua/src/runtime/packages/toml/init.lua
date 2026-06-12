-- toml -- TOML 1.0 decoder / encoder.
--
-- Public surface:
--   toml.decode(text)            -> table
--   toml.encode(table)           -> string
--   toml.datetime(s)             -> tagged datetime literal
--   toml.is_datetime(v)          -> bool
--
-- TOML datetimes are surfaced as { __toml_dt = "<original>" } tables so
-- they round-trip losslessly; helpers wrap/unwrap them.

local M = {}

local sub   = string.sub
local byte  = string.byte
local find  = string.find
local match = string.match
local gmatch= string.gmatch
local rep   = string.rep
local format= string.format
local concat= table.concat
local floor = math.floor
local huge  = math.huge

local _dt_mt = { __toml_dt = true }
function M.datetime(s) return setmetatable({ value = s }, _dt_mt) end
function M.is_datetime(v)
    return type(v) == "table" and getmetatable(v) == _dt_mt
end

-- Array-of-tables marker so encode round-trips correctly.
local _aot_mt = { __toml_aot = true }
function M.array_of_tables(t) return setmetatable(t or {}, _aot_mt) end

-- ===== Decode ==========================================================

local function err(line, msg)
    error(format("toml: %s (line %d)", msg, line), 0)
end

local function is_space(c)
    return c == 0x20 or c == 0x09
end

local function trim(s)
    return (s:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

-- Parse a basic string literal starting at position i (after the opening ").
local function parse_basic_string(s, i, line)
    local len = #s
    local buf, n = {}, 0
    while i <= len do
        local c = byte(s, i)
        if c == 0x22 then  -- "
            return concat(buf), i + 1
        elseif c == 0x5C then  -- \
            local nc = byte(s, i + 1)
            if     nc == 0x22 then n = n + 1; buf[n] = '"';  i = i + 2
            elseif nc == 0x5C then n = n + 1; buf[n] = '\\'; i = i + 2
            elseif nc == 0x62 then n = n + 1; buf[n] = '\b'; i = i + 2
            elseif nc == 0x66 then n = n + 1; buf[n] = '\f'; i = i + 2
            elseif nc == 0x6E then n = n + 1; buf[n] = '\n'; i = i + 2
            elseif nc == 0x72 then n = n + 1; buf[n] = '\r'; i = i + 2
            elseif nc == 0x74 then n = n + 1; buf[n] = '\t'; i = i + 2
            elseif nc == 0x75 then  -- \uXXXX
                local hex = sub(s, i + 2, i + 5)
                local cp = tonumber(hex, 16); if not cp then err(line, "bad \\u escape") end
                n = n + 1; buf[n] = utf8.char(cp)
                i = i + 6
            elseif nc == 0x55 then  -- \UXXXXXXXX
                local hex = sub(s, i + 2, i + 9)
                local cp = tonumber(hex, 16); if not cp then err(line, "bad \\U escape") end
                n = n + 1; buf[n] = utf8.char(cp)
                i = i + 10
            else err(line, "bad escape sequence")
            end
        elseif c == 0x0A then err(line, "unterminated basic string")
        else
            n = n + 1; buf[n] = sub(s, i, i); i = i + 1
        end
    end
    err(line, "unterminated basic string")
end

local function parse_multiline_basic(s, i, line_ref)
    -- Skip immediate newline after opening """.
    if byte(s, i) == 0x0D then i = i + 1 end
    if byte(s, i) == 0x0A then i = i + 1; line_ref.line = line_ref.line + 1 end
    local len = #s
    local buf, n = {}, 0
    while i <= len do
        if sub(s, i, i + 2) == '"""' then
            -- Allow up to two trailing quotes (1 or 2 quotes adjacent to closing).
            local trailing = 0
            while sub(s, i + 3 + trailing, i + 3 + trailing) == '"' and trailing < 2 do
                trailing = trailing + 1
            end
            for t = 1, trailing do n = n + 1; buf[n] = '"' end
            return concat(buf), i + 3 + trailing
        end
        local c = byte(s, i)
        if c == 0x5C then  -- backslash
            local nc = byte(s, i + 1)
            -- Line-ending backslash: gobble whitespace until next non-ws.
            if nc == 0x0A or nc == 0x0D or (nc == 0x20 and find(s, "^[ \t]*[\r\n]", i + 1)) then
                local j = i + 1
                while is_space(byte(s, j) or 0) do j = j + 1 end
                if byte(s, j) == 0x0D then j = j + 1 end
                if byte(s, j) == 0x0A then j = j + 1; line_ref.line = line_ref.line + 1 end
                while is_space(byte(s, j) or 0) or byte(s, j) == 0x0A or byte(s, j) == 0x0D do
                    if byte(s, j) == 0x0A then line_ref.line = line_ref.line + 1 end
                    j = j + 1
                end
                i = j
            elseif nc == 0x22 then n = n + 1; buf[n] = '"';  i = i + 2
            elseif nc == 0x5C then n = n + 1; buf[n] = '\\'; i = i + 2
            elseif nc == 0x62 then n = n + 1; buf[n] = '\b'; i = i + 2
            elseif nc == 0x66 then n = n + 1; buf[n] = '\f'; i = i + 2
            elseif nc == 0x6E then n = n + 1; buf[n] = '\n'; i = i + 2
            elseif nc == 0x72 then n = n + 1; buf[n] = '\r'; i = i + 2
            elseif nc == 0x74 then n = n + 1; buf[n] = '\t'; i = i + 2
            elseif nc == 0x75 then
                local hex = sub(s, i + 2, i + 5)
                local cp = tonumber(hex, 16); if not cp then err(line_ref.line, "bad \\u") end
                n = n + 1; buf[n] = utf8.char(cp); i = i + 6
            elseif nc == 0x55 then
                local hex = sub(s, i + 2, i + 9)
                local cp = tonumber(hex, 16); if not cp then err(line_ref.line, "bad \\U") end
                n = n + 1; buf[n] = utf8.char(cp); i = i + 10
            else err(line_ref.line, "bad escape")
            end
        else
            if c == 0x0A then line_ref.line = line_ref.line + 1 end
            n = n + 1; buf[n] = sub(s, i, i); i = i + 1
        end
    end
    err(line_ref.line, "unterminated multiline basic string")
end

local function parse_literal_string(s, i, line)
    local len = #s
    local start = i
    while i <= len do
        local c = byte(s, i)
        if c == 0x27 then return sub(s, start, i - 1), i + 1 end
        if c == 0x0A then err(line, "unterminated literal string") end
        i = i + 1
    end
    err(line, "unterminated literal string")
end

local function parse_multiline_literal(s, i, line_ref)
    if byte(s, i) == 0x0D then i = i + 1 end
    if byte(s, i) == 0x0A then i = i + 1; line_ref.line = line_ref.line + 1 end
    local start = i
    local len = #s
    while i <= len do
        if sub(s, i, i + 2) == "'''" then
            local trailing = 0
            while sub(s, i + 3 + trailing, i + 3 + trailing) == "'" and trailing < 2 do
                trailing = trailing + 1
            end
            return sub(s, start, i - 1) .. rep("'", trailing), i + 3 + trailing
        end
        if byte(s, i) == 0x0A then line_ref.line = line_ref.line + 1 end
        i = i + 1
    end
    err(line_ref.line, "unterminated multiline literal string")
end

local function parse_key(s, i, line)
    -- Returns a list of key segments (for dotted keys) and the next pos.
    local segments = {}
    while true do
        while is_space(byte(s, i) or 0) do i = i + 1 end
        local c = byte(s, i)
        local seg
        if c == 0x22 then
            seg, i = parse_basic_string(s, i + 1, line)
        elseif c == 0x27 then
            seg, i = parse_literal_string(s, i + 1, line)
        else
            local start = i
            while i <= #s do
                local ch = byte(s, i)
                if (ch >= 0x41 and ch <= 0x5A) or (ch >= 0x61 and ch <= 0x7A)
                or (ch >= 0x30 and ch <= 0x39) or ch == 0x5F or ch == 0x2D then
                    i = i + 1
                else break end
            end
            if i == start then err(line, "expected key") end
            seg = sub(s, start, i - 1)
        end
        segments[#segments + 1] = seg
        while is_space(byte(s, i) or 0) do i = i + 1 end
        if byte(s, i) ~= 0x2E then return segments, i end
        i = i + 1
    end
end

local parse_value

local function parse_number(token, line)
    -- Datetime quick check: contains 'T', 't', ' ' between digits, or trailing 'Z'.
    if match(token, "^%d%d%d%d%-%d%d%-%d%d") then return M.datetime(token) end
    if match(token, "^%d%d:%d%d:%d%d") then return M.datetime(token) end
    if token == "inf" or token == "+inf" then return huge end
    if token == "-inf" then return -huge end
    if token == "nan" or token == "+nan" or token == "-nan" then return 0 / 0 end
    local clean = token:gsub("_", "")
    -- Hex/oct/bin.
    local pref = sub(clean, 1, 2)
    if pref == "0x" then return tonumber(sub(clean, 3), 16) or err(line, "bad hex") end
    if pref == "0o" then return tonumber(sub(clean, 3), 8)  or err(line, "bad oct") end
    if pref == "0b" then return tonumber(sub(clean, 3), 2)  or err(line, "bad bin") end
    local n = tonumber(clean)
    if not n then err(line, "bad number: " .. token) end
    return n
end

local function parse_array(s, i, line_ref)
    local arr = {}
    local n = 0
    i = i + 1  -- past [
    while true do
        -- skip whitespace incl. newlines and comments
        while true do
            local c = byte(s, i)
            if c == 0x20 or c == 0x09 then i = i + 1
            elseif c == 0x0A then line_ref.line = line_ref.line + 1; i = i + 1
            elseif c == 0x0D then i = i + 1
            elseif c == 0x23 then  -- #
                while i <= #s and byte(s, i) ~= 0x0A do i = i + 1 end
            else break end
        end
        if byte(s, i) == 0x5D then return arr, i + 1 end
        local v
        v, i = parse_value(s, i, line_ref)
        n = n + 1; arr[n] = v
        while true do
            local c = byte(s, i)
            if c == 0x20 or c == 0x09 then i = i + 1
            elseif c == 0x0A then line_ref.line = line_ref.line + 1; i = i + 1
            elseif c == 0x0D then i = i + 1
            elseif c == 0x23 then while i <= #s and byte(s, i) ~= 0x0A do i = i + 1 end
            else break end
        end
        local c = byte(s, i)
        if c == 0x2C then i = i + 1
        elseif c == 0x5D then return arr, i + 1
        else err(line_ref.line, "expected ',' or ']' in array") end
    end
end

local function parse_inline_table(s, i, line_ref)
    local t = {}
    i = i + 1  -- past {
    while is_space(byte(s, i) or 0) do i = i + 1 end
    if byte(s, i) == 0x7D then return t, i + 1 end
    while true do
        while is_space(byte(s, i) or 0) do i = i + 1 end
        local segs; segs, i = parse_key(s, i, line_ref.line)
        while is_space(byte(s, i) or 0) do i = i + 1 end
        if byte(s, i) ~= 0x3D then err(line_ref.line, "expected '=' in inline table") end
        i = i + 1
        while is_space(byte(s, i) or 0) do i = i + 1 end
        local v
        v, i = parse_value(s, i, line_ref)
        local cur = t
        for k = 1, #segs - 1 do
            local seg = segs[k]
            if cur[seg] == nil then cur[seg] = {} end
            cur = cur[seg]
        end
        cur[segs[#segs]] = v
        while is_space(byte(s, i) or 0) do i = i + 1 end
        local c = byte(s, i)
        if c == 0x2C then i = i + 1
        elseif c == 0x7D then return t, i + 1
        else err(line_ref.line, "expected ',' or '}' in inline table") end
    end
end

parse_value = function(s, i, line_ref)
    local c = byte(s, i)
    if c == 0x22 then  -- "
        if sub(s, i, i + 2) == '"""' then
            return parse_multiline_basic(s, i + 3, line_ref)
        end
        return parse_basic_string(s, i + 1, line_ref.line)
    elseif c == 0x27 then  -- '
        if sub(s, i, i + 2) == "'''" then
            return parse_multiline_literal(s, i + 3, line_ref)
        end
        return parse_literal_string(s, i + 1, line_ref.line)
    elseif c == 0x5B then  -- [
        return parse_array(s, i, line_ref)
    elseif c == 0x7B then  -- {
        return parse_inline_table(s, i, line_ref)
    end
    -- Literal token: true / false / number / datetime.
    -- Datetime may contain ':' and '-' and space, so we accept up to newline/comment/comma/]/}.
    local start = i
    while i <= #s do
        local ch = byte(s, i)
        if ch == 0x0A or ch == 0x0D or ch == 0x23 or ch == 0x2C or ch == 0x5D or ch == 0x7D then break end
        i = i + 1
    end
    local token = trim(sub(s, start, i - 1))
    if token == "true"  then return true,  i end
    if token == "false" then return false, i end
    -- A datetime may legitimately contain a space between date and time.
    if match(token, "^%d%d%d%d%-%d%d%-%d%d") then
        -- Re-grab to include space-separated time if present.
        -- token already has it because we read up to newline/comma/etc.
        return M.datetime(token), i
    end
    return parse_number(token, line_ref.line), i
end

local function set_path(root, segs, value, line, is_array)
    local cur = root
    for k = 1, #segs - 1 do
        local seg = segs[k]
        local nxt = cur[seg]
        if nxt == nil then
            nxt = {}; cur[seg] = nxt
        elseif type(nxt) ~= "table" then
            err(line, "key conflict at " .. seg)
        elseif getmetatable(nxt) == _aot_mt then
            nxt = nxt[#nxt]  -- descend into the last element
        end
        cur = nxt
    end
    local last = segs[#segs]
    if is_array then
        local existing = cur[last]
        if existing == nil then
            existing = setmetatable({}, _aot_mt); cur[last] = existing
        elseif getmetatable(existing) ~= _aot_mt then
            err(line, "key " .. last .. " is not an array of tables")
        end
        local new = {}
        existing[#existing + 1] = new
        return new
    else
        if cur[last] == nil then cur[last] = {} end
        return cur[last]
    end
end

function M.decode(s)
    if type(s) ~= "string" then error("toml.decode: expected string") end
    -- Strip optional BOM.
    if sub(s, 1, 3) == "\xEF\xBB\xBF" then s = sub(s, 4) end
    local root = {}
    local current = root
    local line_ref = { line = 1 }
    local i, len = 1, #s
    while i <= len do
        local c = byte(s, i)
        if c == 0x20 or c == 0x09 or c == 0x0D then
            i = i + 1
        elseif c == 0x0A then
            line_ref.line = line_ref.line + 1; i = i + 1
        elseif c == 0x23 then  -- comment to EOL
            while i <= len and byte(s, i) ~= 0x0A do i = i + 1 end
        elseif c == 0x5B then  -- [ or [[
            local is_aot = (byte(s, i + 1) == 0x5B)
            i = i + (is_aot and 2 or 1)
            while is_space(byte(s, i) or 0) do i = i + 1 end
            local segs; segs, i = parse_key(s, i, line_ref.line)
            while is_space(byte(s, i) or 0) do i = i + 1 end
            if is_aot then
                if byte(s, i) ~= 0x5D or byte(s, i + 1) ~= 0x5D then
                    err(line_ref.line, "expected ']]'")
                end
                i = i + 2
            else
                if byte(s, i) ~= 0x5D then err(line_ref.line, "expected ']'") end
                i = i + 1
            end
            current = set_path(root, segs, nil, line_ref.line, is_aot)
        else
            local segs; segs, i = parse_key(s, i, line_ref.line)
            while is_space(byte(s, i) or 0) do i = i + 1 end
            if byte(s, i) ~= 0x3D then err(line_ref.line, "expected '='") end
            i = i + 1
            while is_space(byte(s, i) or 0) do i = i + 1 end
            local v
            v, i = parse_value(s, i, line_ref)
            local cur = current
            for k = 1, #segs - 1 do
                if cur[segs[k]] == nil then cur[segs[k]] = {} end
                cur = cur[segs[k]]
            end
            cur[segs[#segs]] = v
            -- Optional trailing whitespace + comment.
            while is_space(byte(s, i) or 0) do i = i + 1 end
            if byte(s, i) == 0x23 then
                while i <= len and byte(s, i) ~= 0x0A do i = i + 1 end
            end
        end
    end
    return root
end

-- ===== Encode ==========================================================

local _bare_key = "^[A-Za-z0-9_-]+$"

local function encode_key(k)
    if type(k) == "string" and match(k, _bare_key) then return k end
    if type(k) ~= "string" then k = tostring(k) end
    return '"' .. (k:gsub('\\', '\\\\'):gsub('"', '\\"')) .. '"'
end

local function encode_string(s)
    local esc = (s:gsub('\\', '\\\\'):gsub('"', '\\"')
                  :gsub('\b', '\\b'):gsub('\f', '\\f')
                  :gsub('\n', '\\n'):gsub('\r', '\\r')
                  :gsub('\t', '\\t'))
    return '"' .. esc .. '"'
end

local encode_value_inline

local function is_array_like(t)
    local n = #t
    if n == 0 then return next(t) == nil end
    for k in pairs(t) do
        if type(k) ~= "number" or k ~= floor(k) or k < 1 or k > n then return false end
    end
    return true
end

encode_value_inline = function(v)
    if v == nil then return "" end
    if M.is_datetime(v) then return v.value end
    local t = type(v)
    if t == "boolean" then return v and "true" or "false" end
    if t == "string"  then return encode_string(v) end
    if t == "number" then
        if v ~= v then return "nan" end
        if v == huge then return "inf" end
        if v == -huge then return "-inf" end
        if math.type and math.type(v) == "integer" then return tostring(v) end
        if v == floor(v) then return format("%.1f", v) end
        return format("%.17g", v)
    end
    if t == "table" then
        if is_array_like(v) then
            local parts = {}
            for i = 1, #v do parts[i] = encode_value_inline(v[i]) end
            return "[" .. concat(parts, ", ") .. "]"
        end
        -- inline table
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1; parts[n] = encode_key(k) .. " = " .. encode_value_inline(val)
        end
        return "{" .. concat(parts, ", ") .. "}"
    end
    error("toml.encode: unsupported type " .. t)
end

local function is_plain_table(v)
    if type(v) ~= "table" then return false end
    if M.is_datetime(v) then return false end
    return not is_array_like(v)
end

local function is_aot(v)
    if type(v) ~= "table" or not is_array_like(v) then return false end
    if #v == 0 then return false end
    for i = 1, #v do
        if not is_plain_table(v[i]) then return false end
    end
    return true
end

local encode_table

encode_table = function(t, path, buf)
    -- First pass: scalars and arrays of scalars/inline-tables go as key=value.
    -- Second pass: nested plain tables get [path.sub] header.
    -- Third pass: arrays-of-tables get [[path.sub]] headers.
    local scalar_keys, nested_keys, aot_keys = {}, {}, {}
    for k in pairs(t) do
        local v = t[k]
        if is_aot(v) then aot_keys[#aot_keys + 1] = k
        elseif is_plain_table(v) then nested_keys[#nested_keys + 1] = k
        else scalar_keys[#scalar_keys + 1] = k end
    end
    table.sort(scalar_keys, function(a, b) return tostring(a) < tostring(b) end)
    table.sort(nested_keys, function(a, b) return tostring(a) < tostring(b) end)
    table.sort(aot_keys,    function(a, b) return tostring(a) < tostring(b) end)

    for _, k in ipairs(scalar_keys) do
        buf[#buf + 1] = encode_key(k) .. " = " .. encode_value_inline(t[k])
    end
    for _, k in ipairs(nested_keys) do
        local new_path = path == "" and encode_key(k) or path .. "." .. encode_key(k)
        if #buf > 0 then buf[#buf + 1] = "" end
        buf[#buf + 1] = "[" .. new_path .. "]"
        encode_table(t[k], new_path, buf)
    end
    for _, k in ipairs(aot_keys) do
        local new_path = path == "" and encode_key(k) or path .. "." .. encode_key(k)
        for i = 1, #t[k] do
            if #buf > 0 then buf[#buf + 1] = "" end
            buf[#buf + 1] = "[[" .. new_path .. "]]"
            encode_table(t[k][i], new_path, buf)
        end
    end
end

function M.encode(t)
    if type(t) ~= "table" then error("toml.encode: expected table") end
    local buf = {}
    encode_table(t, "", buf)
    return concat(buf, "\n") .. "\n"
end

return M
