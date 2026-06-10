-- xml -- tolerant XML 1.0 parser + writer.
--
-- Public surface:
--   xml.parse(text)               -> root_node
--   xml.parse_sax(text, handlers) -- handlers: { on_start, on_end, on_text, on_cdata, on_pi, on_comment, on_decl }
--   xml.serialize(node, opts?)    -> string  (opts: { pretty=true, indent="  ", xml_decl=true })
--   xml.encode_entities(s)
--   xml.decode_entities(s)
--   xml.find(node, tag)           -> first child with tag
--   xml.find_all(node, tag)       -> { children with tag }
--   xml.text(node)                -> concatenated text content
--
-- Node shape: { tag = "name", attrs = { key = value }, children = { ... } }
-- Children can be strings (text) or nested nodes.

local M = {}

local sub    = string.sub
local find   = string.find
local byte   = string.byte
local match  = string.match
local gmatch = string.gmatch
local concat = table.concat

-- ===== Entities =========================================================

local _entities = {
    amp  = "&",
    lt   = "<",
    gt   = ">",
    quot = '"',
    apos = "'",
}

local function decode_entity(name)
    if sub(name, 1, 2) == "#x" or sub(name, 1, 2) == "#X" then
        local cp = tonumber(sub(name, 3), 16)
        if cp then return utf8.char(cp) end
    elseif sub(name, 1, 1) == "#" then
        local cp = tonumber(sub(name, 2))
        if cp then return utf8.char(cp) end
    end
    return _entities[name] or ("&" .. name .. ";")
end

function M.decode_entities(s)
    return (s:gsub("&([^;&]+);", decode_entity))
end

local _enc_map = {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&apos;",
}

function M.encode_entities(s)
    return (s:gsub('[&<>"\']', _enc_map))
end

-- ===== SAX parser =======================================================

local function err(line, msg)
    error(string.format("xml: %s (line %d)", msg, line), 0)
end

local function count_lines(s, from, to)
    local c = 0
    for i = from, to do
        if byte(s, i) == 0x0A then c = c + 1 end
    end
    return c
end

local function parse_attrs(s, line)
    -- s contains the attribute-list portion of a start tag.
    local attrs = {}
    local i, len = 1, #s
    while i <= len do
        -- Skip whitespace.
        while i <= len do
            local c = byte(s, i)
            if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D then i = i + 1
            else break end
        end
        if i > len then break end
        -- Name.
        local name_start = i
        while i <= len do
            local c = byte(s, i)
            if c == 0x3D or c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D then break end
            i = i + 1
        end
        local name = sub(s, name_start, i - 1)
        if name == "" then break end
        while i <= len and (byte(s, i) == 0x20 or byte(s, i) == 0x09) do i = i + 1 end
        if byte(s, i) ~= 0x3D then
            -- HTML-style boolean attr -- tolerate.
            attrs[name] = name
        else
            i = i + 1
            while i <= len and (byte(s, i) == 0x20 or byte(s, i) == 0x09) do i = i + 1 end
            local q = byte(s, i)
            local val
            if q == 0x22 or q == 0x27 then
                local close = sub(s, i, i)
                local vs = i + 1
                local ve = find(s, close, vs, true)
                if not ve then err(line, "unterminated attribute value") end
                val = M.decode_entities(sub(s, vs, ve - 1))
                i = ve + 1
            else
                -- Unquoted -- read until whitespace.
                local vs = i
                while i <= len do
                    local c = byte(s, i)
                    if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D then break end
                    i = i + 1
                end
                val = M.decode_entities(sub(s, vs, i - 1))
            end
            attrs[name] = val
        end
    end
    return attrs
end

function M.parse_sax(text, h)
    h = h or {}
    local on_start   = h.on_start   or function() end
    local on_end     = h.on_end     or function() end
    local on_text    = h.on_text    or function() end
    local on_cdata   = h.on_cdata   or function() end
    local on_pi      = h.on_pi      or function() end
    local on_comment = h.on_comment or function() end
    local on_decl    = h.on_decl    or function() end

    if sub(text, 1, 3) == "\xEF\xBB\xBF" then text = sub(text, 4) end
    local i, len = 1, #text
    local line = 1
    while i <= len do
        local lt = find(text, "<", i, true)
        if not lt then
            -- Trailing text.
            local rest = sub(text, i)
            if rest ~= "" then on_text(M.decode_entities(rest)) end
            return
        end
        if lt > i then
            local raw = sub(text, i, lt - 1)
            on_text(M.decode_entities(raw))
            line = line + count_lines(text, i, lt - 1)
        end
        local nc = byte(text, lt + 1)
        if nc == 0x21 then  -- !
            if sub(text, lt + 2, lt + 3) == "--" then  -- comment
                local ce = find(text, "-->", lt + 4, true)
                if not ce then err(line, "unterminated comment") end
                on_comment(sub(text, lt + 4, ce - 1))
                line = line + count_lines(text, lt, ce + 2)
                i = ce + 3
            elseif sub(text, lt + 2, lt + 8) == "[CDATA[" then
                local ce = find(text, "]]>", lt + 9, true)
                if not ce then err(line, "unterminated CDATA") end
                on_cdata(sub(text, lt + 9, ce - 1))
                line = line + count_lines(text, lt, ce + 2)
                i = ce + 3
            else
                -- DOCTYPE or similar -- skip to matching >
                local ge = find(text, ">", lt + 2, true)
                if not ge then err(line, "unterminated <! declaration") end
                line = line + count_lines(text, lt, ge)
                i = ge + 1
            end
        elseif nc == 0x3F then  -- ?
            local pe = find(text, "?>", lt + 2, true)
            if not pe then err(line, "unterminated processing instruction") end
            local body = sub(text, lt + 2, pe - 1)
            local target, rest = match(body, "^(%S+)%s*(.*)$")
            if target == "xml" then
                local attrs = parse_attrs(rest or "", line)
                on_decl(attrs)
            else
                on_pi(target, rest or "")
            end
            line = line + count_lines(text, lt, pe + 1)
            i = pe + 2
        elseif nc == 0x2F then  -- /
            local ge = find(text, ">", lt + 2, true)
            if not ge then err(line, "unterminated end tag") end
            local tag = sub(text, lt + 2, ge - 1):gsub("%s+$", "")
            on_end(tag)
            line = line + count_lines(text, lt, ge)
            i = ge + 1
        else
            local ge = find(text, ">", lt + 1, true)
            if not ge then err(line, "unterminated start tag") end
            local body = sub(text, lt + 1, ge - 1)
            local self_close = false
            if sub(body, -1) == "/" then
                self_close = true
                body = sub(body, 1, -2):gsub("%s+$", "")
            end
            local tag, after = match(body, "^([^%s/]+)(.*)$")
            if not tag then err(line, "malformed start tag") end
            local attrs = parse_attrs(after or "", line)
            on_start(tag, attrs, self_close)
            if self_close then on_end(tag) end
            line = line + count_lines(text, lt, ge)
            i = ge + 1
        end
    end
end

-- ===== DOM parser =======================================================

function M.parse(text)
    local root = { tag = nil, attrs = {}, children = {} }
    local stack = { root }
    local function top() return stack[#stack] end
    local function push_text(s)
        if s == "" then return end
        local node = top()
        local kids = node.children
        local last = kids[#kids]
        if type(last) == "string" then
            kids[#kids] = last .. s
        else
            kids[#kids + 1] = s
        end
    end
    M.parse_sax(text, {
        on_start = function(tag, attrs)
            local node = { tag = tag, attrs = attrs, children = {} }
            top().children[#top().children + 1] = node
            stack[#stack + 1] = node
        end,
        on_end = function(tag)
            if top().tag ~= tag then
                error("xml: mismatched closing tag " .. tag .. " (expected " .. (top().tag or "?") .. ")")
            end
            stack[#stack] = nil
        end,
        on_text = push_text,
        on_cdata = push_text,
    })
    -- Return the first element child of the synthetic root.
    for _, c in ipairs(root.children) do
        if type(c) == "table" then return c end
    end
    return root
end

-- ===== Serialize ========================================================

local function serialize_node(node, buf, depth, pretty, indent)
    if type(node) == "string" then
        buf[#buf + 1] = M.encode_entities(node)
        return
    end
    local pad = pretty and (indent:rep(depth)) or ""
    if pretty then buf[#buf + 1] = pad end
    buf[#buf + 1] = "<" .. node.tag
    if node.attrs then
        -- Stable ordering.
        local keys, n = {}, 0
        for k in pairs(node.attrs) do n = n + 1; keys[n] = k end
        table.sort(keys)
        for i = 1, n do
            local k = keys[i]
            buf[#buf + 1] = " " .. k .. '="' .. M.encode_entities(tostring(node.attrs[k])) .. '"'
        end
    end
    local kids = node.children or {}
    if #kids == 0 then
        buf[#buf + 1] = "/>"
        if pretty then buf[#buf + 1] = "\n" end
        return
    end
    buf[#buf + 1] = ">"
    -- Mixed content: if any child is text (a string), serialize this node
    -- inline (no injected newlines/indentation) so round-trips preserve text.
    -- Pretty indentation is only safe when children are exclusively elements.
    local has_element_child = false
    local has_text_child = false
    for _, c in ipairs(kids) do
        if type(c) == "table" then has_element_child = true
        else has_text_child = true end
    end
    local block = pretty and has_element_child and not has_text_child
    if block then buf[#buf + 1] = "\n" end
    for _, c in ipairs(kids) do
        if block then
            serialize_node(c, buf, depth + 1, pretty, indent)
        else
            if type(c) == "string" then
                buf[#buf + 1] = M.encode_entities(c)
            else
                serialize_node(c, buf, depth + 1, false, indent)
            end
        end
    end
    if block then buf[#buf + 1] = pad end
    buf[#buf + 1] = "</" .. node.tag .. ">"
    if pretty then buf[#buf + 1] = "\n" end
end

function M.serialize(node, opts)
    opts = opts or {}
    local pretty = opts.pretty
    local indent = opts.indent or "  "
    local buf = {}
    if opts.xml_decl then
        buf[#buf + 1] = '<?xml version="1.0" encoding="UTF-8"?>\n'
    end
    serialize_node(node, buf, 0, pretty, indent)
    return concat(buf)
end

-- ===== Convenience accessors ===========================================

function M.find(node, tag)
    for _, c in ipairs(node.children or {}) do
        if type(c) == "table" and c.tag == tag then return c end
    end
end

function M.find_all(node, tag)
    local out, n = {}, 0
    for _, c in ipairs(node.children or {}) do
        if type(c) == "table" and c.tag == tag then n = n + 1; out[n] = c end
    end
    return out
end

function M.text(node)
    local parts, n = {}, 0
    for _, c in ipairs(node.children or {}) do
        if type(c) == "string" then n = n + 1; parts[n] = c
        elseif type(c) == "table" then n = n + 1; parts[n] = M.text(c) end
    end
    return concat(parts)
end

return M
