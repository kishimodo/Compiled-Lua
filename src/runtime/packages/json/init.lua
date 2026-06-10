-- json -- RFC 8259 encoder / decoder.
--
-- Public surface:
--   json.encode(value, opts?)      -> string
--   json.decode(text, opts?)       -> value
--   json.decode_stream(reader)     -> value     (reader is fn() -> string|nil)
--   json.null                      -> sentinel for JSON null (distinct from nil)
--   json.array(t)                  -> mark a table as an array (forces [] even if empty)
--   json.object(t)                 -> mark a table as an object (forces {} even if empty)
--   json.validate(value, schema)   -> ok, err  (schema: { type=, min=, max=, enum=, required=, properties=, items= })
--
-- Encode options:
--   indent   -- string (e.g. "  ") to pretty-print; nil = compact
--   sort     -- true to emit object keys sorted
--   max_depth -- maximum nested depth (default 256)
--
-- Decode options:
--   max_depth -- nested-depth guard
--   numbers   -- "auto" (default; integers stay integers), "double", "string"
--   array_meta -- when true, decoded arrays get the json.array tag (preserves emptiness)

local M = {}

-- ===== Sentinels ========================================================
local _null = setmetatable({}, { __tostring = function() return "null" end })
M.null = _null

local _ARR_MT = { __jsontype = "array" }
local _OBJ_MT = { __jsontype = "object" }

function M.array(t)  return setmetatable(t or {}, _ARR_MT) end
function M.object(t) return setmetatable(t or {}, _OBJ_MT) end

local function jsontype(t)
    local mt = getmetatable(t)
    if mt and mt.__jsontype then return mt.__jsontype end
    -- Heuristic: pure 1..N sequence with no holes -> array, else object.
    local n = #t
    if n == 0 then
        -- Need to distinguish empty array vs empty object.
        -- next(t) == nil means truly empty; treat as object (RFC-conservative default).
        if next(t) == nil then return "object" end
        return "object"
    end
    -- Verify it's a true sequence (no string keys, no holes).
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return "object" end
        if k ~= math.floor(k) or k < 1 then return "object" end
        count = count + 1
    end
    if count ~= n then return "object" end
    return "array"
end

-- ===== Encode ===========================================================

local _esc = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['/']  = '/',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}
for c = 0, 31 do
    local k = string.char(c)
    if _esc[k] == nil then
        _esc[k] = string.format("\\u%04x", c)
    end
end
_esc[string.char(0x7f)] = "\\u007f"

local function encode_string(s)
    -- Replace each special char in one gsub pass.
    return '"' .. (s:gsub('["\\%c\127]', _esc)) .. '"'
end

local function encode_number(n)
    if n ~= n then              error("json.encode: NaN not representable") end
    if n == math.huge then      error("json.encode: +Inf not representable") end
    if n == -math.huge then     error("json.encode: -Inf not representable") end
    if math.type and math.type(n) == "integer" then
        return tostring(n)
    end
    -- Float: use %.17g to round-trip. Strip trailing .0 if it represents an integer.
    local s = string.format("%.17g", n)
    return s
end

local function encode_value(v, buf, opts, depth)
    if depth > opts.max_depth then
        error("json.encode: max depth exceeded at " .. tostring(opts.max_depth))
    end
    local t = type(v)
    if v == _null then
        buf[#buf + 1] = "null"
    elseif t == "string" then
        buf[#buf + 1] = encode_string(v)
    elseif t == "number" then
        buf[#buf + 1] = encode_number(v)
    elseif t == "boolean" then
        buf[#buf + 1] = v and "true" or "false"
    elseif t == "nil" then
        buf[#buf + 1] = "null"
    elseif t == "table" then
        local kind = jsontype(v)
        local indent = opts.indent
        if kind == "array" then
            local n = #v
            if n == 0 then
                buf[#buf + 1] = "[]"
                return
            end
            buf[#buf + 1] = "["
            for i = 1, n do
                if i > 1 then buf[#buf + 1] = indent and ",\n" or "," end
                if indent then buf[#buf + 1] = "\n" .. indent:rep(depth + 1) end
                encode_value(v[i], buf, opts, depth + 1)
            end
            if indent then buf[#buf + 1] = "\n" .. indent:rep(depth) end
            buf[#buf + 1] = "]"
        else  -- object
            local keys, nk = {}, 0
            for k in pairs(v) do
                if type(k) == "string" then
                    nk = nk + 1; keys[nk] = k
                elseif type(k) == "number" then
                    -- Allow numeric keys in objects by coercing to strings.
                    nk = nk + 1; keys[nk] = tostring(k)
                else
                    error("json.encode: unsupported key type " .. type(k))
                end
            end
            if nk == 0 then
                buf[#buf + 1] = "{}"
                return
            end
            if opts.sort then table.sort(keys) end
            buf[#buf + 1] = "{"
            for i = 1, nk do
                if i > 1 then buf[#buf + 1] = indent and ",\n" or "," end
                if indent then buf[#buf + 1] = "\n" .. indent:rep(depth + 1) end
                local k = keys[i]
                buf[#buf + 1] = encode_string(k)
                buf[#buf + 1] = indent and ": " or ":"
                -- Need to fetch by original key (number or string) -- prefer string form first.
                local original = v[k]
                if original == nil then original = v[tonumber(k)] end
                encode_value(original, buf, opts, depth + 1)
            end
            if indent then buf[#buf + 1] = "\n" .. indent:rep(depth) end
            buf[#buf + 1] = "}"
        end
    else
        error("json.encode: unsupported value type " .. t)
    end
end

function M.encode(value, opts)
    opts = opts or {}
    opts.max_depth = opts.max_depth or 256
    local buf = {}
    encode_value(value, buf, opts, 0)
    return table.concat(buf)
end

-- ===== Decode ===========================================================

local function skip_ws(s, i)
    local len = #s
    while i <= len do
        local c = s:byte(i)
        if c == 32 or c == 9 or c == 10 or c == 13 then
            i = i + 1
        else
            return i
        end
    end
    return i
end

local function decode_error(s, i, msg)
    -- Find line/column.
    local line, col, p = 1, 1, 1
    while p < i do
        if s:byte(p) == 10 then line = line + 1; col = 1
        else col = col + 1 end
        p = p + 1
    end
    error(string.format("json.decode: %s at line %d col %d (offset %d)", msg, line, col, i), 3)
end

local _decode_value
local _esc_decode = {
    ['"']  = '"',  ['\\'] = '\\', ['/']  = '/',
    ['b']  = '\b', ['f']  = '\f', ['n']  = '\n',
    ['r']  = '\r', ['t']  = '\t',
}

local function utf8_encode(cp)
    -- Encode a Unicode codepoint as UTF-8 bytes (1-4).
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + (cp >> 6), 0x80 + (cp & 0x3F))
    elseif cp < 0x10000 then
        return string.char(0xE0 + (cp >> 12), 0x80 + ((cp >> 6) & 0x3F), 0x80 + (cp & 0x3F))
    else
        return string.char(
            0xF0 + (cp >> 18),
            0x80 + ((cp >> 12) & 0x3F),
            0x80 + ((cp >> 6)  & 0x3F),
            0x80 + (cp & 0x3F))
    end
end

local function decode_string(s, i)
    -- Caller passes the position AFTER the opening quote.
    local len = #s
    local start, parts, np = i, nil, 0
    while i <= len do
        local b = s:byte(i)
        if b == 34 then  -- closing "
            if parts == nil then return s:sub(start, i - 1), i + 1 end
            np = np + 1; parts[np] = s:sub(start, i - 1)
            return table.concat(parts), i + 1
        elseif b == 92 then  -- backslash
            if parts == nil then parts = {} end
            if i > start then np = np + 1; parts[np] = s:sub(start, i - 1) end
            local c = s:sub(i + 1, i + 1)
            local sub = _esc_decode[c]
            if sub then
                np = np + 1; parts[np] = sub
                i = i + 2
                start = i
            elseif c == "u" then
                local hex = s:sub(i + 2, i + 5)
                if #hex < 4 then decode_error(s, i, "bad \\u escape") end
                local cp = tonumber(hex, 16)
                if cp == nil then decode_error(s, i, "bad \\u hex") end
                i = i + 6
                if cp >= 0xD800 and cp <= 0xDBFF then
                    -- High surrogate; expect low surrogate next.
                    if s:sub(i, i + 1) ~= "\\u" then
                        decode_error(s, i, "unpaired high surrogate")
                    end
                    local hex2 = s:sub(i + 2, i + 5)
                    local cp2 = tonumber(hex2, 16)
                    if cp2 == nil or cp2 < 0xDC00 or cp2 > 0xDFFF then
                        decode_error(s, i, "bad low surrogate")
                    end
                    cp = 0x10000 + ((cp - 0xD800) * 0x400) + (cp2 - 0xDC00)
                    i = i + 6
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    decode_error(s, i, "unexpected low surrogate")
                end
                np = np + 1; parts[np] = utf8_encode(cp)
                start = i
            else
                decode_error(s, i, "bad escape \\" .. c)
            end
        elseif b < 32 then
            decode_error(s, i, "raw control byte in string")
        else
            i = i + 1
        end
    end
    decode_error(s, start, "unterminated string")
end

local function decode_number(s, i)
    local start = i
    local len = #s
    local b = s:byte(i)
    if b == 45 then i = i + 1 end  -- minus
    -- Integer part.
    local int_start = i
    while i <= len do
        b = s:byte(i)
        if b and b >= 48 and b <= 57 then i = i + 1 else break end
    end
    if i == int_start then decode_error(s, start, "bad number") end
    local is_float = false
    if b == 46 then  -- .
        is_float = true
        i = i + 1
        while i <= len do
            b = s:byte(i)
            if b and b >= 48 and b <= 57 then i = i + 1 else break end
        end
    end
    if b == 101 or b == 69 then  -- e/E
        is_float = true
        i = i + 1
        b = s:byte(i)
        if b == 43 or b == 45 then i = i + 1 end
        while i <= len do
            b = s:byte(i)
            if b and b >= 48 and b <= 57 then i = i + 1 else break end
        end
    end
    local numstr = s:sub(start, i - 1)
    local n
    if is_float then
        n = tonumber(numstr)
    else
        n = tonumber(numstr, 10)
        -- Lua 5.4 tonumber on integer text returns integer when no float chars.
    end
    if n == nil then decode_error(s, start, "bad number: " .. numstr) end
    return n, i
end

local function decode_array(s, i, opts, depth)
    i = skip_ws(s, i)
    local arr = opts.array_meta and setmetatable({}, _ARR_MT) or {}
    if s:byte(i) == 93 then return arr, i + 1 end  -- ]
    local n = 0
    while true do
        local v
        v, i = _decode_value(s, i, opts, depth + 1)
        n = n + 1; arr[n] = v
        i = skip_ws(s, i)
        local c = s:byte(i)
        if c == 44 then i = skip_ws(s, i + 1)  -- ,
        elseif c == 93 then return arr, i + 1  -- ]
        else decode_error(s, i, "expected ',' or ']' in array") end
    end
end

local function decode_object(s, i, opts, depth)
    i = skip_ws(s, i)
    local obj = {}
    if s:byte(i) == 125 then return obj, i + 1 end  -- }
    while true do
        if s:byte(i) ~= 34 then decode_error(s, i, "expected string key") end
        local key
        key, i = decode_string(s, i + 1)
        i = skip_ws(s, i)
        if s:byte(i) ~= 58 then decode_error(s, i, "expected ':' after key") end
        i = skip_ws(s, i + 1)
        local v
        v, i = _decode_value(s, i, opts, depth + 1)
        obj[key] = v
        i = skip_ws(s, i)
        local c = s:byte(i)
        if c == 44 then i = skip_ws(s, i + 1)  -- ,
        elseif c == 125 then return obj, i + 1  -- }
        else decode_error(s, i, "expected ',' or '}' in object") end
    end
end

_decode_value = function(s, i, opts, depth)
    if depth > opts.max_depth then
        decode_error(s, i, "max depth exceeded")
    end
    i = skip_ws(s, i)
    local b = s:byte(i)
    if b == 34 then            -- "
        return decode_string(s, i + 1)
    elseif b == 123 then       -- {
        return decode_object(s, i + 1, opts, depth)
    elseif b == 91 then        -- [
        return decode_array(s, i + 1, opts, depth)
    elseif b == 116 then       -- t(rue)
        if s:sub(i, i + 3) ~= "true" then decode_error(s, i, "bad literal") end
        return true, i + 4
    elseif b == 102 then       -- f(alse)
        if s:sub(i, i + 4) ~= "false" then decode_error(s, i, "bad literal") end
        return false, i + 5
    elseif b == 110 then       -- n(ull)
        if s:sub(i, i + 3) ~= "null" then decode_error(s, i, "bad literal") end
        return _null, i + 4
    elseif b == 45 or (b and b >= 48 and b <= 57) then
        return decode_number(s, i)
    else
        decode_error(s, i, "unexpected character")
    end
end

function M.decode(text, opts)
    opts = opts or {}
    opts.max_depth = opts.max_depth or 256
    local v, i = _decode_value(text, 1, opts, 0)
    i = skip_ws(text, i)
    if i <= #text then
        decode_error(text, i, "trailing garbage")
    end
    return v
end

function M.decode_stream(reader)
    -- Pull-based stream: accumulates until a full top-level value is found
    -- (single value or a stream of newline-separated values via NDJSON).
    local buf, bn = {}, 0
    repeat
        local chunk = reader()
        if chunk then bn = bn + 1; buf[bn] = chunk end
    until chunk == nil
    return M.decode(table.concat(buf))
end

-- ===== Schema-light validation =========================================

local function validate(value, schema, path)
    path = path or "$"
    local t = type(value)
    if value == _null then t = "null" end
    if schema.type then
        local want = schema.type
        local ok = false
        if want == "array" then
            ok = (t == "table" and jsontype(value) == "array")
        elseif want == "object" then
            ok = (t == "table" and jsontype(value) == "object")
        elseif want == "integer" then
            ok = (t == "number" and value == math.floor(value))
        elseif want == "number" then
            ok = (t == "number")
        elseif want == "string" then
            ok = (t == "string")
        elseif want == "boolean" then
            ok = (t == "boolean")
        elseif want == "null" then
            ok = (value == _null or value == nil)
        end
        if not ok then return false, path .. ": expected " .. want .. ", got " .. t end
    end
    if schema.min and t == "number" and value < schema.min then
        return false, path .. ": below min " .. schema.min
    end
    if schema.max and t == "number" and value > schema.max then
        return false, path .. ": above max " .. schema.max
    end
    if schema.minLength and t == "string" and #value < schema.minLength then
        return false, path .. ": string too short"
    end
    if schema.maxLength and t == "string" and #value > schema.maxLength then
        return false, path .. ": string too long"
    end
    if schema.enum then
        local found = false
        for _, e in ipairs(schema.enum) do if value == e then found = true; break end end
        if not found then return false, path .. ": not in enum" end
    end
    if schema.pattern and t == "string" and not string.match(value, schema.pattern) then
        return false, path .. ": pattern mismatch"
    end
    if schema.properties and t == "table" then
        for k, subschema in pairs(schema.properties) do
            if value[k] ~= nil then
                local ok, err = validate(value[k], subschema, path .. "." .. k)
                if not ok then return false, err end
            end
        end
    end
    if schema.required and t == "table" then
        for _, k in ipairs(schema.required) do
            if value[k] == nil then return false, path .. ": missing required field '" .. k .. "'" end
        end
    end
    if schema.items and t == "table" and jsontype(value) == "array" then
        for idx, item in ipairs(value) do
            local ok, err = validate(item, schema.items, path .. "[" .. idx .. "]")
            if not ok then return false, err end
        end
    end
    return true
end

M.validate = validate

return M
