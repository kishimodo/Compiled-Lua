-- yaml -- YAML 1.2 subset decoder / encoder.
--
-- Public surface:
--   yaml.decode(text)            -> first document's value
--   yaml.decode_all(text)        -> { doc1, doc2, ... }
--   yaml.encode(value)           -> string (single document)
--   yaml.encode_all(values)      -> string (multi-document, --- separated)
--   yaml.null                    -> sentinel for explicit null
--
-- Supported: block mappings + sequences with indentation, flow mappings {a:b}
-- and sequences [a,b], block scalars | and > (with chomping indicators),
-- double-quoted and single-quoted strings, anchors &x and aliases *x,
-- explicit !!str/!!int/!!float/!!bool/!!null tags, multi-doc streams.

local M = {}

local sub    = string.sub
local find   = string.find
local match  = string.match
local gmatch = string.gmatch
local byte   = string.byte
local format = string.format
local concat = table.concat
local floor  = math.floor
local huge   = math.huge

local _null = setmetatable({}, { __tostring = function() return "yaml.null" end })
M.null = _null

-- ===== Tokenize into logical lines ======================================

local function split_lines(s)
    -- Normalize line endings and split, keeping every line (including blanks).
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    local start = 1
    for i = 1, #s do
        if byte(s, i) == 0x0A then
            lines[#lines + 1] = sub(s, start, i - 1)
            start = i + 1
        end
    end
    if start <= #s then lines[#lines + 1] = sub(s, start) end
    return lines
end

local function indent_of(line)
    local i = 1
    while i <= #line and byte(line, i) == 0x20 do i = i + 1 end
    if i <= #line and byte(line, i) == 0x09 then
        error("yaml: tab in indentation")
    end
    return i - 1
end

local function strip_comment(line)
    -- Remove an unquoted '#' comment. Only honors '#' preceded by space or BOL.
    local i, in_dq, in_sq = 1, false, false
    while i <= #line do
        local c = byte(line, i)
        if in_dq then
            if c == 0x5C then i = i + 2
            elseif c == 0x22 then in_dq = false; i = i + 1
            else i = i + 1 end
        elseif in_sq then
            if c == 0x27 then
                if byte(line, i + 1) == 0x27 then i = i + 2
                else in_sq = false; i = i + 1 end
            else i = i + 1 end
        else
            if c == 0x22 then in_dq = true; i = i + 1
            elseif c == 0x27 then in_sq = true; i = i + 1
            elseif c == 0x23 and (i == 1 or byte(line, i - 1) == 0x20) then
                return (sub(line, 1, i - 1):gsub("%s+$", ""))
            else i = i + 1 end
        end
    end
    return (line:gsub("%s+$", ""))
end

-- ===== Scalar parsing ===================================================

local _dq_esc = {
    ['n'] = '\n', ['t'] = '\t', ['r'] = '\r', ['0'] = '\0',
    ['\\'] = '\\', ['"'] = '"', ['/'] = '/', ['b'] = '\b',
    ['f'] = '\f', ['a'] = '\a', ['v'] = '\v', [' '] = ' ',
    ['e'] = '\27',
}

local function parse_dq_string(s)
    -- s is the content between the quotes.
    local out, n, i = {}, 0, 1
    while i <= #s do
        local c = sub(s, i, i)
        if c == "\\" then
            local nc = sub(s, i + 1, i + 1)
            if _dq_esc[nc] then
                n = n + 1; out[n] = _dq_esc[nc]
                i = i + 2
            elseif nc == "x" then
                local cp = tonumber(sub(s, i + 2, i + 3), 16)
                n = n + 1; out[n] = utf8.char(cp); i = i + 4
            elseif nc == "u" then
                local cp = tonumber(sub(s, i + 2, i + 5), 16)
                n = n + 1; out[n] = utf8.char(cp); i = i + 6
            elseif nc == "U" then
                local cp = tonumber(sub(s, i + 2, i + 9), 16)
                n = n + 1; out[n] = utf8.char(cp); i = i + 10
            else
                n = n + 1; out[n] = nc; i = i + 2
            end
        else
            n = n + 1; out[n] = c; i = i + 1
        end
    end
    return concat(out)
end

local function parse_sq_string(s)
    -- Single-quoted: only escape is '' -> '.
    return (s:gsub("''", "'"))
end

local function parse_plain_scalar(s)
    if s == "" then return _null end
    if s == "~" or s == "null" or s == "Null" or s == "NULL" then return _null end
    if s == "true"  or s == "True"  or s == "TRUE"  then return true end
    if s == "false" or s == "False" or s == "FALSE" then return false end
    if s == ".nan" or s == ".NaN" or s == ".NAN" then return 0 / 0 end
    if s == ".inf" or s == ".Inf" or s == ".INF" or s == "+.inf" then return huge end
    if s == "-.inf" or s == "-.Inf" or s == "-.INF" then return -huge end
    -- Integer (decimal, hex, octal).
    if match(s, "^[+-]?%d+$") then
        local n = tonumber(s); if n then return n end
    end
    if match(s, "^0x[0-9A-Fa-f]+$") then return tonumber(sub(s, 3), 16) end
    if match(s, "^0o[0-7]+$") then return tonumber(sub(s, 3), 8) end
    -- Float. NOTE: Lua patterns do NOT support `?` on a capture group, so the
    -- optional exponent must be spelled out as separate with/without-exponent
    -- alternatives rather than `([eE][+-]?%d+)?` (which silently never matches,
    -- leaving plain floats like "3.14" or "1.5" as strings).
    if match(s, "^[+-]?%d*%.%d+$")                  -- .5 / 3.14   (no exponent)
    or match(s, "^[+-]?%d*%.%d+[eE][+-]?%d+$")      -- 3.14e2
    or match(s, "^[+-]?%d+%.%d*$")                  -- 3. / 3.0    (no exponent)
    or match(s, "^[+-]?%d+%.%d*[eE][+-]?%d+$")      -- 3.0e2
    or match(s, "^[+-]?%d+[eE][+-]?%d+$") then      -- 1e10
        local n = tonumber(s); if n then return n end
    end
    return s
end

local function apply_tag(tag, value)
    if not tag then return value end
    if     tag == "!!str"   then return tostring(value)
    elseif tag == "!!int"   then return tonumber(value) or value
    elseif tag == "!!float" then return tonumber(value) or value
    elseif tag == "!!bool"  then
        if value == "true" or value == "True"  or value == true  then return true  end
        if value == "false" or value == "False" or value == false then return false end
        return value
    elseif tag == "!!null"  then return _null
    end
    return value
end

-- Parse a flow scalar from a string position, returning (value, next_pos).
local function parse_flow_value(s, i)
    -- Skip leading spaces.
    while byte(s, i) == 0x20 do i = i + 1 end
    local c = byte(s, i)
    if c == 0x22 then  -- "
        local j = i + 1
        while j <= #s do
            local cc = byte(s, j)
            if cc == 0x5C then j = j + 2
            elseif cc == 0x22 then break
            else j = j + 1 end
        end
        return parse_dq_string(sub(s, i + 1, j - 1)), j + 1
    elseif c == 0x27 then  -- '
        local j = i + 1
        while j <= #s do
            if byte(s, j) == 0x27 then
                if byte(s, j + 1) == 0x27 then j = j + 2
                else break end
            else j = j + 1 end
        end
        return parse_sq_string(sub(s, i + 1, j - 1)), j + 1
    elseif c == 0x7B then  -- {
        local out, j = {}, i + 1
        while true do
            while byte(s, j) == 0x20 or byte(s, j) == 0x2C do j = j + 1 end
            if j > #s then break end              -- unterminated flow: stop
            if byte(s, j) == 0x7D then return out, j + 1 end
            local k, v
            local pj = j                          -- progress guard
            k, j = parse_flow_value(s, j)
            while byte(s, j) == 0x20 do j = j + 1 end
            if byte(s, j) == 0x3A then
                j = j + 1
                v, j = parse_flow_value(s, j)
            else
                v = _null
            end
            out[k] = v
            if j <= pj then break end             -- no progress: stop (malformed)
        end
        return out, j
    elseif c == 0x5B then  -- [
        local out, n, j = {}, 0, i + 1
        while true do
            while byte(s, j) == 0x20 or byte(s, j) == 0x2C do j = j + 1 end
            if j > #s then break end              -- unterminated flow: stop
            if byte(s, j) == 0x5D then return out, j + 1 end
            local pj = j                          -- progress guard
            local v; v, j = parse_flow_value(s, j)
            n = n + 1; out[n] = v
            if j <= pj then break end             -- no progress: stop (malformed)
        end
        return out, j
    end
    -- Plain scalar: until , } ] or end.
    local start = i
    while i <= #s do
        local cc = byte(s, i)
        if cc == 0x2C or cc == 0x7D or cc == 0x5D or cc == 0x3A then break end
        i = i + 1
    end
    return parse_plain_scalar((sub(s, start, i - 1):gsub("^%s+", ""):gsub("%s+$", ""))), i
end

-- ===== Block parser =====================================================

local function parse_block(lines, ln, indent, anchors)
    -- Returns (value, next_ln).
    local len = #lines
    -- Skip blank/comment lines at this level.
    while ln <= len do
        local line = lines[ln]
        local stripped = strip_comment(line)
        if stripped:match("^%s*$") then
            ln = ln + 1
        elseif stripped:match("^%s*#") then
            ln = ln + 1
        else
            break
        end
    end
    if ln > len then return _null, ln end
    local line = strip_comment(lines[ln])
    local cur_indent = indent_of(line)
    if cur_indent < indent then return _null, ln end
    local rest = sub(line, cur_indent + 1)

    -- Flow collection as a complete node on one line (`{a: 1}` / `[1, 2]`),
    -- e.g. a top-level flow document. MUST be handled before mapping detection
    -- below, whose colon scan is not flow-aware: an inner `:` would otherwise
    -- be taken as a block-mapping separator and misparse (historically: hang).
    if rest:sub(1, 1) == "{" or rest:sub(1, 1) == "[" then
        local v = parse_flow_value(rest, 1)
        return v, ln + 1
    end

    -- Sequence: starts with "- ".
    if rest:sub(1, 2) == "- " or rest == "-" then
        local seq = {}
        local n = 0
        while ln <= len do
            line = strip_comment(lines[ln])
            if line:match("^%s*$") then ln = ln + 1
            else
                local ind = indent_of(line)
                if ind < cur_indent then break end
                if ind > cur_indent then break end
                rest = sub(line, ind + 1)
                if rest:sub(1, 2) ~= "- " and rest ~= "-" then break end
                -- Item content is everything after "- ".
                local item_content = rest == "-" and "" or sub(rest, 3)
                if item_content == "" then
                    -- Nested content on subsequent lines, indented deeper.
                    local v
                    v, ln = parse_block(lines, ln + 1, cur_indent + 2, anchors)
                    n = n + 1; seq[n] = v
                else
                    -- Could be inline mapping start ("- key: value") or a scalar/flow.
                    local k = item_content:match("^([^%s].-):%s*(.*)$")
                    if k and not item_content:match("^[%[%{\"']") then
                        local val_str = item_content:match("^[^%s].-:%s*(.*)$")
                        -- Treat the dash position as the start of a mapping.
                        local item_indent = cur_indent + 2
                        local synthetic = {}
                        synthetic[#synthetic + 1] = string.rep(" ", item_indent) .. item_content
                        for j = ln + 1, len do synthetic[#synthetic + 1] = lines[j] end
                        local v, used = parse_block(synthetic, 1, item_indent, anchors)
                        n = n + 1; seq[n] = v
                        ln = ln + (used - 1)
                    else
                        local v = parse_flow_value(item_content, 1)
                        n = n + 1; seq[n] = v
                        ln = ln + 1
                    end
                end
            end
        end
        return seq, ln
    end

    -- Block scalar header.
    if rest == "|" or rest == ">" or rest:match("^[|>][-+]?%d*$") then
        local style = sub(rest, 1, 1)
        local chomp = rest:match("[%-+]")
        local parts, n = {}, 0
        local content_indent
        ln = ln + 1
        while ln <= len do
            local lraw = lines[ln]
            if lraw == "" or lraw:match("^%s*$") then
                n = n + 1; parts[n] = ""
                ln = ln + 1
            else
                local lind = indent_of(lraw)
                if not content_indent then
                    if lind <= cur_indent then break end
                    content_indent = lind
                end
                if lind < content_indent then break end
                n = n + 1; parts[n] = sub(lraw, content_indent + 1)
                ln = ln + 1
            end
        end
        local body
        if style == "|" then
            body = concat(parts, "\n")
        else  -- folded
            local folded = {}
            for i, p in ipairs(parts) do
                folded[i] = p
            end
            body = concat(folded, " "):gsub("  +", "\n")
        end
        if chomp == "-" then body = body:gsub("\n+$", "")
        elseif chomp == "+" then  -- keep
        else body = body:gsub("\n+$", "") .. "\n"
        end
        return body, ln
    end

    -- Mapping: line contains "key: value" or "key:" with nested block.
    -- Mapping detection: a colon that is not inside flow/quoted context.
    local in_dq, in_sq, ci = false, false, nil
    for i = 1, #rest do
        local c = byte(rest, i)
        if in_dq then
            if c == 0x5C then -- skip
            elseif c == 0x22 then in_dq = false end
        elseif in_sq then
            if c == 0x27 then in_sq = false end
        else
            if c == 0x22 then in_dq = true
            elseif c == 0x27 then in_sq = true
            elseif c == 0x3A and (i == #rest or byte(rest, i + 1) == 0x20) then
                ci = i; break
            end
        end
    end

    if ci then
        local map = {}
        while ln <= len do
            line = strip_comment(lines[ln])
            if line:match("^%s*$") then ln = ln + 1
            else
                local ind = indent_of(line)
                if ind ~= cur_indent then break end
                rest = sub(line, ind + 1)
                -- Re-find colon.
                in_dq, in_sq, ci = false, false, nil
                for i = 1, #rest do
                    local c = byte(rest, i)
                    if in_dq then
                        if c == 0x5C then
                        elseif c == 0x22 then in_dq = false end
                    elseif in_sq then
                        if c == 0x27 then in_sq = false end
                    else
                        if c == 0x22 then in_dq = true
                        elseif c == 0x27 then in_sq = true
                        elseif c == 0x3A and (i == #rest or byte(rest, i + 1) == 0x20) then
                            ci = i; break
                        end
                    end
                end
                if not ci then break end
                local key_raw = sub(rest, 1, ci - 1):gsub("%s+$", "")
                local key = parse_flow_value(key_raw, 1)
                local val_raw = sub(rest, ci + 1):gsub("^%s+", "")
                -- Anchor / alias on value.
                local anchor
                if sub(val_raw, 1, 1) == "&" then
                    local space = find(val_raw, " ") or (#val_raw + 1)
                    anchor = sub(val_raw, 2, space - 1)
                    val_raw = sub(val_raw, space + 1):gsub("^%s+", "")
                end
                local v
                if sub(val_raw, 1, 1) == "*" then
                    local name = sub(val_raw, 2)
                    v = anchors[name]
                    ln = ln + 1
                elseif val_raw == "" then
                    v, ln = parse_block(lines, ln + 1, cur_indent + 1, anchors)
                else
                    v = parse_flow_value(val_raw, 1)
                    ln = ln + 1
                end
                if anchor then anchors[anchor] = v end
                map[key] = v
            end
        end
        return map, ln
    end

    -- Plain scalar or flow value.
    local v = parse_flow_value(rest, 1)
    return v, ln + 1
end

-- ===== Public decode entries ============================================

local function decode_documents(text)
    if type(text) ~= "string" then error("yaml.decode: expected string") end
    if sub(text, 1, 3) == "\xEF\xBB\xBF" then text = sub(text, 4) end
    local lines = split_lines(text)
    -- Split into documents by --- / ... markers.
    local docs, cur, cn = {}, {}, 0
    for i = 1, #lines do
        local l = lines[i]
        if l == "---" or l:match("^%-%-%-%s") or l == "..." then
            if cn > 0 then docs[#docs + 1] = cur end
            cur, cn = {}, 0
        else
            cn = cn + 1; cur[cn] = l
        end
    end
    if cn > 0 then docs[#docs + 1] = cur end
    if #docs == 0 then docs[1] = lines end

    local out = {}
    for di, doc_lines in ipairs(docs) do
        local anchors = {}
        local v = parse_block(doc_lines, 1, 0, anchors)
        out[di] = v
    end
    return out
end

function M.decode(text)
    local docs = decode_documents(text)
    return docs[1]
end

function M.decode_all(text)
    return decode_documents(text)
end

-- ===== Encode ===========================================================

local function needs_quoting(s)
    if s == "" then return true end
    if s == "null" or s == "true" or s == "false" or s == "~" then return true end
    if tonumber(s) then return true end
    if match(s, "[:#%[%]{}&*!|>'\"%%@`,]") then return true end
    if match(s, "^[%s%-?]") or match(s, "[%s]$") then return true end
    return false
end

local function encode_string(s)
    if needs_quoting(s) then
        return '"' .. (s:gsub('\\', '\\\\')
                        :gsub('"', '\\"')
                        :gsub('\n', '\\n')
                        :gsub('\r', '\\r')
                        :gsub('\t', '\\t')) .. '"'
    end
    return s
end

local function is_array(t)
    local n = #t
    if n == 0 then return next(t) == nil end
    for k in pairs(t) do
        if type(k) ~= "number" or k ~= floor(k) or k < 1 or k > n then return false end
    end
    return true
end

local encode_value

encode_value = function(v, indent, top_level)
    if v == nil or v == _null then return "null" end
    local t = type(v)
    if t == "boolean" then return v and "true" or "false" end
    if t == "string"  then return encode_string(v) end
    if t == "number" then
        if v ~= v then return ".nan" end
        if v == huge then return ".inf" end
        if v == -huge then return "-.inf" end
        if math.type and math.type(v) == "integer" then return tostring(v) end
        return format("%.17g", v)
    end
    if t == "table" then
        local pad = string.rep("  ", indent)
        if is_array(v) then
            if #v == 0 then return "[]" end
            local parts = {}
            for i = 1, #v do
                local sv = v[i]
                if type(sv) == "table" and (sv ~= _null) and next(sv) ~= nil then
                    if is_array(sv) and #sv > 0 then
                        parts[i] = pad .. "-\n" .. encode_value(sv, indent + 1, false)
                    else
                        -- Inline first key on dash line.
                        local first_line = pad .. "- "
                        local inner = encode_value(sv, indent + 1, false)
                        -- Strip indent of first inner line so it sits next to "- ".
                        local inner_pad = string.rep("  ", indent + 1)
                        inner = inner:gsub("^" .. inner_pad, "")
                        parts[i] = first_line .. inner
                    end
                else
                    parts[i] = pad .. "- " .. encode_value(sv, indent + 1, false)
                end
            end
            local res = concat(parts, "\n")
            if not top_level then return res end
            return res
        else
            local keys, n = {}, 0
            for k in pairs(v) do n = n + 1; keys[n] = k end
            if n == 0 then return "{}" end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local parts = {}
            for i = 1, n do
                local k = keys[i]
                local sv = v[k]
                local key_str = encode_string(tostring(k))
                if type(sv) == "table" and sv ~= _null and next(sv) ~= nil then
                    parts[i] = pad .. key_str .. ":\n" .. encode_value(sv, indent + 1, false)
                else
                    parts[i] = pad .. key_str .. ": " .. encode_value(sv, indent + 1, false)
                end
            end
            return concat(parts, "\n")
        end
    end
    error("yaml.encode: unsupported type " .. t)
end

function M.encode(v)
    return encode_value(v, 0, true) .. "\n"
end

function M.encode_all(values)
    local parts = {}
    for i, v in ipairs(values) do
        parts[i] = "---\n" .. encode_value(v, 0, true)
    end
    return concat(parts, "\n") .. "\n"
end

return M
