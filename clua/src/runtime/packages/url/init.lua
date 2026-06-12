-- url -- RFC 3986 parser, formatter and percent-encoder.
--
-- Public surface:
--   url.parse(s)            -> { scheme, userinfo, host, port, path, query, fragment }
--   url.format(parts)       -> string
--   url.encode_component(s) -> string   (encodes everything outside unreserved)
--   url.decode_component(s) -> string
--   url.encode_path(s)      -> string   (preserves path-safe chars per RFC 3986 pchar)
--   url.encode_query(s)     -> string   (form-encoding: space -> '+')
--   url.decode_query(s)     -> string
--   url.encode_userinfo(s)  -> string
--   url.encode_host(s)      -> string

local M = {}

-- Unreserved: A-Z a-z 0-9 - . _ ~
local function is_unreserved(b)
    return (b >= 0x30 and b <= 0x39)   -- 0-9
        or (b >= 0x41 and b <= 0x5A)   -- A-Z
        or (b >= 0x61 and b <= 0x7A)   -- a-z
        or b == 0x2D or b == 0x2E or b == 0x5F or b == 0x7E  -- -._~
end

-- Sub-delims: ! $ & ' ( ) * + , ; =
local function is_subdelim(b)
    return b == 0x21 or b == 0x24 or b == 0x26 or b == 0x27
        or b == 0x28 or b == 0x29 or b == 0x2A or b == 0x2B
        or b == 0x2C or b == 0x3B or b == 0x3D
end

local function pct(b) return string.format("%%%02X", b) end

local function encode_with(s, allow)
    if type(s) ~= "string" then
        error("url.encode: expected string, got " .. type(s))
    end
    local out, n = {}, 0
    for i = 1, #s do
        local b = s:byte(i)
        if allow(b) then
            n = n + 1; out[n] = string.char(b)
        else
            n = n + 1; out[n] = pct(b)
        end
    end
    return table.concat(out)
end

function M.encode_component(s)
    -- Encodes everything except unreserved.
    return encode_with(s, is_unreserved)
end

function M.encode_path(s)
    -- pchar = unreserved / pct-encoded / sub-delims / ":" / "@", plus '/' allowed in segments.
    return encode_with(s, function(b)
        return is_unreserved(b) or is_subdelim(b)
            or b == 0x3A or b == 0x40 or b == 0x2F
    end)
end

function M.encode_query(s)
    -- application/x-www-form-urlencoded: space -> '+', everything else percent-encoded
    -- except unreserved.
    local out, n = {}, 0
    for i = 1, #s do
        local b = s:byte(i)
        if b == 0x20 then
            n = n + 1; out[n] = "+"
        elseif is_unreserved(b) then
            n = n + 1; out[n] = string.char(b)
        else
            n = n + 1; out[n] = pct(b)
        end
    end
    return table.concat(out)
end

function M.encode_userinfo(s)
    -- userinfo = *( unreserved / pct-encoded / sub-delims / ":" )
    return encode_with(s, function(b)
        return is_unreserved(b) or is_subdelim(b) or b == 0x3A
    end)
end

function M.encode_host(s)
    -- For reg-name hosts; bracketed IP-literals should be encoded externally.
    return encode_with(s, function(b)
        return is_unreserved(b) or is_subdelim(b)
    end)
end

function M.decode_component(s)
    if type(s) ~= "string" then
        error("url.decode_component: expected string, got " .. type(s))
    end
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

function M.decode_query(s)
    if type(s) ~= "string" then
        error("url.decode_query: expected string, got " .. type(s))
    end
    -- form-encoding: '+' is space.
    local replaced = s:gsub("%+", " ")
    return (replaced:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Parse per RFC 3986 appendix B regex, but written explicitly.
function M.parse(s)
    if type(s) ~= "string" then
        error("url.parse: expected string, got " .. type(s))
    end
    local parts = { scheme = nil, userinfo = nil, host = nil, port = nil,
                    path = "", query = nil, fragment = nil }

    -- Fragment first.
    local hash = s:find("#", 1, true)
    if hash then
        parts.fragment = s:sub(hash + 1)
        s = s:sub(1, hash - 1)
    end

    -- Query.
    local q = s:find("?", 1, true)
    if q then
        parts.query = s:sub(q + 1)
        s = s:sub(1, q - 1)
    end

    -- Scheme: scheme ":" hier-part, where scheme must start with ALPHA.
    local colon = s:find(":", 1, true)
    if colon then
        local maybe = s:sub(1, colon - 1)
        if maybe:match("^%a[%w%+%-%.]*$") then
            parts.scheme = maybe:lower()
            s = s:sub(colon + 1)
        end
    end

    -- Authority: starts with "//".
    if s:sub(1, 2) == "//" then
        s = s:sub(3)
        -- Authority terminates at first '/', '?' or '#' (but we've stripped ? and #).
        local slash = s:find("/", 1, true)
        local authority
        if slash then
            authority = s:sub(1, slash - 1)
            s = s:sub(slash)
        else
            authority = s
            s = ""
        end
        -- userinfo split.
        local at = authority:find("@", 1, true)
        if at then
            parts.userinfo = authority:sub(1, at - 1)
            authority = authority:sub(at + 1)
        end
        -- IP-literal "[...]:port" vs "host:port" vs "host".
        if authority:sub(1, 1) == "[" then
            local close = authority:find("]", 1, true)
            if not close then
                error("url.parse: unterminated IP-literal in authority")
            end
            parts.host = authority:sub(1, close)
            local rest = authority:sub(close + 1)
            if rest ~= "" then
                if rest:sub(1, 1) ~= ":" then
                    error("url.parse: junk after IP-literal in authority")
                end
                parts.port = tonumber(rest:sub(2))
                if parts.port == nil then
                    error("url.parse: invalid port '" .. rest:sub(2) .. "'")
                end
            end
        else
            local cc = authority:find(":", 1, true)
            if cc then
                parts.host = authority:sub(1, cc - 1)
                local port_str = authority:sub(cc + 1)
                if port_str ~= "" then
                    parts.port = tonumber(port_str)
                    if parts.port == nil then
                        error("url.parse: invalid port '" .. port_str .. "'")
                    end
                end
            else
                parts.host = authority
            end
        end
    end

    parts.path = s
    return parts
end

function M.format(parts)
    if type(parts) ~= "table" then
        error("url.format: expected table, got " .. type(parts))
    end
    local out, n = {}, 0
    if parts.scheme then
        n = n + 1; out[n] = parts.scheme
        n = n + 1; out[n] = ":"
    end
    if parts.host or parts.userinfo then
        n = n + 1; out[n] = "//"
        if parts.userinfo then
            n = n + 1; out[n] = parts.userinfo
            n = n + 1; out[n] = "@"
        end
        if parts.host then
            n = n + 1; out[n] = parts.host
        end
        if parts.port then
            n = n + 1; out[n] = ":"
            n = n + 1; out[n] = tostring(parts.port)
        end
    end
    if parts.path then
        n = n + 1; out[n] = parts.path
    end
    if parts.query then
        n = n + 1; out[n] = "?"
        n = n + 1; out[n] = parts.query
    end
    if parts.fragment then
        n = n + 1; out[n] = "#"
        n = n + 1; out[n] = parts.fragment
    end
    return table.concat(out)
end

return M
