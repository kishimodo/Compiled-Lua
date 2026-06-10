-- querystring -- application/x-www-form-urlencoded.
--
-- Public surface:
--   querystring.decode(s)         -> { key = value | { values... } }
--   querystring.encode(t, opts?)  -> string
--   querystring.decode_array(s)   -> { { key, value }, ... }   preserves order + duplicates
--   querystring.encode_array(t)   -> string                    from { { key, value }, ... }
--
-- opts (encode):
--   sep -- separator character, default '&'
--   eq  -- key/value separator, default '='

local M = {}

local function is_unreserved(b)
    return (b >= 0x30 and b <= 0x39)
        or (b >= 0x41 and b <= 0x5A)
        or (b >= 0x61 and b <= 0x7A)
        or b == 0x2D or b == 0x2E or b == 0x5F or b == 0x7E
end

local function encode_one(s)
    if type(s) == "number" then s = tostring(s) end
    if type(s) ~= "string" then
        error("querystring.encode: expected string/number, got " .. type(s))
    end
    local out, n = {}, 0
    for i = 1, #s do
        local b = s:byte(i)
        if b == 0x20 then
            n = n + 1; out[n] = "+"
        elseif is_unreserved(b) then
            n = n + 1; out[n] = string.char(b)
        else
            n = n + 1; out[n] = string.format("%%%02X", b)
        end
    end
    return table.concat(out)
end

local function decode_one(s)
    local replaced = s:gsub("%+", " ")
    return (replaced:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

function M.decode(s)
    if type(s) ~= "string" then
        error("querystring.decode: expected string, got " .. type(s))
    end
    local out = {}
    if s == "" then return out end
    -- Split on '&' or ';' -- both are common separators in HTML5 form data.
    for pair in s:gmatch("[^&;]+") do
        local eq = pair:find("=", 1, true)
        local k, v
        if eq then
            k = decode_one(pair:sub(1, eq - 1))
            v = decode_one(pair:sub(eq + 1))
        else
            k = decode_one(pair)
            v = ""
        end
        local existing = out[k]
        if existing == nil then
            out[k] = v
        elseif type(existing) == "table" then
            existing[#existing + 1] = v
        else
            out[k] = { existing, v }
        end
    end
    return out
end

function M.encode(t, opts)
    if type(t) ~= "table" then
        error("querystring.encode: expected table, got " .. type(t))
    end
    opts = opts or {}
    local sep = opts.sep or "&"
    local eq  = opts.eq or "="
    local out, n = {}, 0
    -- Sort keys for stable output.
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = t[k]
        local ek = encode_one(k)
        if type(v) == "table" then
            for i = 1, #v do
                if n > 0 then n = n + 1; out[n] = sep end
                n = n + 1; out[n] = ek
                n = n + 1; out[n] = eq
                n = n + 1; out[n] = encode_one(v[i])
            end
        elseif v == nil or v == false then
            -- skip
        else
            if n > 0 then n = n + 1; out[n] = sep end
            n = n + 1; out[n] = ek
            n = n + 1; out[n] = eq
            n = n + 1; out[n] = encode_one(v)
        end
    end
    return table.concat(out)
end

function M.decode_array(s)
    if type(s) ~= "string" then
        error("querystring.decode_array: expected string, got " .. type(s))
    end
    local out, n = {}, 0
    if s == "" then return out end
    for pair in s:gmatch("[^&;]+") do
        local eq = pair:find("=", 1, true)
        local k, v
        if eq then
            k = decode_one(pair:sub(1, eq - 1))
            v = decode_one(pair:sub(eq + 1))
        else
            k = decode_one(pair)
            v = ""
        end
        n = n + 1; out[n] = { k, v }
    end
    return out
end

function M.encode_array(t, opts)
    if type(t) ~= "table" then
        error("querystring.encode_array: expected table, got " .. type(t))
    end
    opts = opts or {}
    local sep = opts.sep or "&"
    local eq  = opts.eq or "="
    local out, n = {}, 0
    for i = 1, #t do
        local pair = t[i]
        if type(pair) ~= "table" or #pair < 1 then
            error("querystring.encode_array: each entry must be {key, value}")
        end
        if i > 1 then n = n + 1; out[n] = sep end
        n = n + 1; out[n] = encode_one(pair[1])
        n = n + 1; out[n] = eq
        n = n + 1; out[n] = encode_one(pair[2] or "")
    end
    return table.concat(out)
end

return M
