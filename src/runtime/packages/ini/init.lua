-- ini -- classic INI decoder / encoder.
--
-- Public surface:
--   ini.decode(text, opts?)   -> table
--   ini.encode(table, opts?)  -> string
--
-- Options:
--   opts.list_separator (decode) -- if set, value with that char is split into an array
--   opts.lowercase_keys (decode) -- normalize keys/sections to lowercase
--   opts.section_sort   (encode) -- emit sections in sorted order
--
-- Default decode behavior:
--   * Sectionless keys at the top live directly in the returned table.
--   * [section] introduces a sub-table; [a.b] introduces nested a -> b.
--   * Comment chars: ';' and '#' at line start or after unquoted whitespace.
--   * Duplicate keys in the same section get promoted to an array of values.
--   * "true"/"false" -> booleans, plain numbers -> numbers, "null"/"" -> "" (empty string).
--     Wrap values in quotes to force string type and preserve whitespace.

local M = {}

local sub    = string.sub
local find   = string.find
local match  = string.match
local format = string.format
local concat = table.concat
local gmatch = string.gmatch

-- ===== Decode ==========================================================

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local _esc = {
    ["n"] = "\n", ["t"] = "\t", ["r"] = "\r", ["0"] = "\0",
    ["\\"] = "\\", ['"'] = '"', ["'"] = "'", [";"] = ";", ["#"] = "#",
    ["a"] = "\a", ["b"] = "\b", ["f"] = "\f", ["v"] = "\v",
}

local function unescape(s)
    local out, n, i = {}, 0, 1
    while i <= #s do
        local c = sub(s, i, i)
        if c == "\\" then
            local nc = sub(s, i + 1, i + 1)
            if _esc[nc] then
                n = n + 1; out[n] = _esc[nc]; i = i + 2
            elseif nc == "x" then
                local cp = tonumber(sub(s, i + 2, i + 3), 16)
                if cp then n = n + 1; out[n] = string.char(cp); i = i + 4
                else n = n + 1; out[n] = "\\"; i = i + 1 end
            elseif nc == "u" then
                local cp = tonumber(sub(s, i + 2, i + 5), 16)
                if cp then n = n + 1; out[n] = utf8.char(cp); i = i + 6
                else n = n + 1; out[n] = "\\"; i = i + 1 end
            else
                n = n + 1; out[n] = nc; i = i + 2
            end
        else
            n = n + 1; out[n] = c; i = i + 1
        end
    end
    return concat(out)
end

local function strip_inline_comment(s)
    -- Strip ; / # outside of quotes.
    local in_dq, in_sq = false, false
    for i = 1, #s do
        local c = sub(s, i, i)
        if in_dq then
            if c == "\\" and i < #s then  -- skip escape
            elseif c == '"' then in_dq = false end
        elseif in_sq then
            if c == "'" then in_sq = false end
        else
            if c == '"' then in_dq = true
            elseif c == "'" then in_sq = true
            elseif (c == ";" or c == "#") then
                local prev = i > 1 and sub(s, i - 1, i - 1)
                if not prev or prev:match("%s") then
                    return sub(s, 1, i - 1)
                end
            end
        end
    end
    return s
end

local function coerce(v)
    if v == "true"  or v == "True"  or v == "TRUE"  then return true end
    if v == "false" or v == "False" or v == "FALSE" then return false end
    -- Documented mapping (see header): "null" decodes to "" (empty string), not
    -- Lua nil -- returning nil would drop a scalar `k = null` key entirely and
    -- contradict the header, and previously made the list path special-case nil.
    if v == "null"  or v == "Null"  or v == "NULL"  then return "" end
    local n = tonumber(v)
    if n then return n end
    return v
end

local function parse_value(raw, opts)
    raw = strip_inline_comment(raw)
    raw = trim(raw)
    if raw == "" then return "" end
    local first = sub(raw, 1, 1)
    if first == '"' then
        local last = sub(raw, -1)
        if last == '"' then return unescape(sub(raw, 2, -2)) end
    elseif first == "'" then
        local last = sub(raw, -1)
        if last == "'" then return sub(raw, 2, -2) end
    end
    if opts.list_separator and find(raw, opts.list_separator, 1, true) then
        local items, n = {}, 0
        for item in gmatch(raw, "([^" .. opts.list_separator .. "]+)") do
            -- Track an explicit index so a member never collapses the array.
            -- coerce maps "null" -> "" (the documented scalar mapping), so list
            -- and scalar nulls agree; the nil guard stays as defense in depth.
            local v = coerce(trim(item))
            if v == nil then v = "" end
            n = n + 1
            items[n] = v
        end
        return items
    end
    return coerce(unescape(raw))
end

local function set_path(root, section_path, key, value)
    local cur = root
    for _, seg in ipairs(section_path) do
        if cur[seg] == nil then cur[seg] = {} end
        cur = cur[seg]
    end
    local existing = cur[key]
    if existing == nil then
        cur[key] = value
    elseif type(existing) == "table" and getmetatable(existing) == nil
        and (#existing > 0 or next(existing) == nil)
        and (function()
            -- Detect "looks like array" -- safer to convert on duplicate.
            for k in pairs(existing) do if type(k) ~= "number" then return false end end
            return true
        end)() and existing[1] ~= nil then
        existing[#existing + 1] = value
    else
        cur[key] = { existing, value }
    end
end

function M.decode(text, opts)
    opts = opts or {}
    if type(text) ~= "string" then error("ini.decode: expected string") end
    if sub(text, 1, 3) == "\xEF\xBB\xBF" then text = sub(text, 4) end
    local root = {}
    local section = {}
    local cont, cont_key, cont_value
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in gmatch(text .. "\n", "([^\n]*)\n") do
        local raw = line
        local stripped = trim(raw)
        if stripped == "" then
            -- blank
        elseif sub(stripped, 1, 1) == ";" or sub(stripped, 1, 1) == "#" then
            -- comment
        elseif sub(stripped, 1, 1) == "[" then
            local name = match(stripped, "^%[(.-)%]")
            if not name then error("ini: bad section line: " .. line) end
            if opts.lowercase_keys then name = name:lower() end
            section = {}
            for seg in gmatch(name, "[^.]+") do section[#section + 1] = trim(seg) end
        else
            -- Line continuation: prior value ending in unescaped backslash.
            if cont then
                cont_value = cont_value .. trim(raw)
                if sub(cont_value, -1) == "\\" and sub(cont_value, -2, -2) ~= "\\" then
                    cont_value = sub(cont_value, 1, -2)
                else
                    set_path(root, section, cont_key, parse_value(cont_value, opts))
                    cont, cont_key, cont_value = nil, nil, nil
                end
            else
                local k, sep, v = match(stripped, "^([^=:]-)([=:])(.*)$")
                if not k then
                    -- Bare key (no value).
                    if opts.lowercase_keys then stripped = stripped:lower() end
                    set_path(root, section, stripped, "")
                else
                    k = trim(k)
                    if opts.lowercase_keys then k = k:lower() end
                    v = v or ""
                    if sub(trim(v), -1) == "\\" and sub(trim(v), -2, -2) ~= "\\" then
                        cont = true
                        cont_key = k
                        cont_value = sub(trim(v), 1, -2)
                    else
                        set_path(root, section, k, parse_value(v, opts))
                    end
                end
            end
        end
    end
    if cont then set_path(root, section, cont_key, parse_value(cont_value, opts)) end
    return root
end

-- ===== Encode ==========================================================

local function needs_quoting(s)
    if s == "" then return false end
    if match(s, "[\n\r\t;#=:\\]") then return true end
    if match(s, "^%s") or match(s, "%s$") then return true end
    return false
end

local function escape(s)
    return (s:gsub('\\', '\\\\')
             :gsub('"', '\\"')
             :gsub('\n', '\\n')
             :gsub('\r', '\\r')
             :gsub('\t', '\\t')
             :gsub(';', '\\;')
             :gsub('#', '\\#'))
end

local function fmt_scalar(v)
    if v == nil then return "" end
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then
        if math.type and math.type(v) == "integer" then return tostring(v) end
        return format("%.17g", v)
    end
    if type(v) == "string" then
        if needs_quoting(v) then return '"' .. escape(v) .. '"' end
        return v
    end
    error("ini.encode: unsupported scalar type " .. type(v))
end

local function is_section(v)
    if type(v) ~= "table" then return false end
    for k in pairs(v) do
        if type(k) ~= "string" then return false end
    end
    return next(v) ~= nil
end

local function emit_section(buf, name, t, opts)
    if name ~= "" then
        buf[#buf + 1] = "[" .. name .. "]"
    end
    local keys, n = {}, 0
    for k, v in pairs(t) do
        if not is_section(v) then n = n + 1; keys[n] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "table" then
            -- array of scalars
            for _, item in ipairs(v) do
                buf[#buf + 1] = k .. "=" .. fmt_scalar(item)
            end
        else
            buf[#buf + 1] = k .. "=" .. fmt_scalar(v)
        end
    end
    -- Now nested sections.
    local subkeys, sn = {}, 0
    for k, v in pairs(t) do
        if is_section(v) then sn = sn + 1; subkeys[sn] = k end
    end
    if opts.section_sort then
        table.sort(subkeys, function(a, b) return tostring(a) < tostring(b) end)
    end
    for _, sk in ipairs(subkeys) do
        local sub_name = name == "" and sk or (name .. "." .. sk)
        buf[#buf + 1] = ""
        emit_section(buf, sub_name, t[sk], opts)
    end
end

function M.encode(t, opts)
    opts = opts or {}
    if type(t) ~= "table" then error("ini.encode: expected table") end
    local buf = {}
    emit_section(buf, "", t, opts)
    return concat(buf, "\n") .. "\n"
end

return M
