-- mime -- MIME helpers.
--
-- Public surface:
--   mime.lookup(name)                          -> "type/subtype" | nil
--   mime.extension(content_type)               -> ".ext" | nil   (best-effort reverse)
--   mime.parse_multipart(body, boundary)       -> { parts... }
--   mime.format_multipart(parts, boundary)     -> string
--   mime.parse_content_type(s)                 -> { type, params = { ... } }
--
-- A multipart "part" is { headers = { ["name"] = "value", ... }, body = "..." }.

local M = {}

-- Common MIME types -- kept short and focused on widespread formats.
local TYPES = {
    txt   = "text/plain",
    html  = "text/html",
    htm   = "text/html",
    css   = "text/css",
    csv   = "text/csv",
    md    = "text/markdown",
    xml   = "application/xml",
    json  = "application/json",
    js    = "application/javascript",
    mjs   = "application/javascript",
    wasm  = "application/wasm",
    pdf   = "application/pdf",
    zip   = "application/zip",
    gz    = "application/gzip",
    tar   = "application/x-tar",
    ["7z"] = "application/x-7z-compressed",
    rar   = "application/vnd.rar",
    bz2   = "application/x-bzip2",
    xz    = "application/x-xz",
    bin   = "application/octet-stream",
    exe   = "application/vnd.microsoft.portable-executable",
    dll   = "application/vnd.microsoft.portable-executable",
    doc   = "application/msword",
    docx  = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    xls   = "application/vnd.ms-excel",
    xlsx  = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ppt   = "application/vnd.ms-powerpoint",
    pptx  = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    -- images
    png   = "image/png",
    jpg   = "image/jpeg",
    jpeg  = "image/jpeg",
    gif   = "image/gif",
    bmp   = "image/bmp",
    webp  = "image/webp",
    svg   = "image/svg+xml",
    ico   = "image/x-icon",
    tif   = "image/tiff",
    tiff  = "image/tiff",
    avif  = "image/avif",
    -- audio
    mp3   = "audio/mpeg",
    m4a   = "audio/mp4",
    wav   = "audio/wav",
    flac  = "audio/flac",
    ogg   = "audio/ogg",
    opus  = "audio/opus",
    aac   = "audio/aac",
    -- video
    mp4   = "video/mp4",
    m4v   = "video/mp4",
    mkv   = "video/x-matroska",
    webm  = "video/webm",
    mov   = "video/quicktime",
    avi   = "video/x-msvideo",
    mpeg  = "video/mpeg",
    -- fonts
    ttf   = "font/ttf",
    otf   = "font/otf",
    woff  = "font/woff",
    woff2 = "font/woff2",
    -- data
    yaml  = "application/yaml",
    yml   = "application/yaml",
    toml  = "application/toml",
    sql   = "application/sql",
    -- shell / source
    lua   = "text/x-lua",
    py    = "text/x-python",
    rb    = "text/x-ruby",
    c     = "text/x-c",
    h     = "text/x-c",
    cpp   = "text/x-c++",
    rs    = "text/x-rust",
    go    = "text/x-go",
    sh    = "application/x-sh",
    ps1   = "application/x-powershell",
}

-- Reverse lookup -- one ext per type (first-wins).
local EXTS = {}
for ext, ct in pairs(TYPES) do
    if EXTS[ct] == nil then EXTS[ct] = "." .. ext end
end

function M.lookup(name)
    if type(name) ~= "string" then
        error("mime.lookup: expected string, got " .. type(name))
    end
    -- Strip any leading dot.
    local lower = name:lower()
    -- If a filename or path, take the part after the last '.'.
    local last_dot = lower:match(".*%.(.+)$")
    local ext = last_dot or lower:gsub("^%.", "")
    return TYPES[ext]
end

function M.extension(content_type)
    if type(content_type) ~= "string" then
        error("mime.extension: expected string, got " .. type(content_type))
    end
    -- Drop parameters like "; charset=utf-8".
    local main = content_type:match("^([^;]+)")
    if main then main = main:gsub("%s+", ""):lower() end
    return EXTS[main]
end

function M.parse_content_type(s)
    if type(s) ~= "string" then
        error("mime.parse_content_type: expected string, got " .. type(s))
    end
    local result = { type = nil, params = {} }
    local main, rest = s:match("^%s*([^;]+)(.*)$")
    if not main then return result end
    result.type = main:gsub("%s+", ""):lower()
    if rest and rest ~= "" then
        -- Parse `; key=value` parameters with a small scanner that respects
        -- quoted-string values. A naive `[^;]+` value pattern splits on a ';'
        -- INSIDE a quoted value (e.g. charset="a;b"), which RFC 2045/7231
        -- explicitly permit; scan the quote run instead.
        local i, n = 1, #rest
        while i <= n do
            local semi = rest:find(";", i, true)
            if not semi then break end
            i = semi + 1
            local _, ke, key = rest:find("^%s*([%w%-_]+)%s*=%s*", i)
            if key then
                i = ke + 1
                local value
                if rest:sub(i, i) == '"' then
                    local close = rest:find('"', i + 1, true)
                    if close then
                        value = rest:sub(i + 1, close - 1)
                        i = close + 1
                    else
                        value = rest:sub(i + 1)   -- unterminated quote
                        i = n + 1
                    end
                else
                    local ve = rest:find(";", i, true)
                    if ve then
                        value = (rest:sub(i, ve - 1):gsub("%s+$", ""))
                        i = ve
                    else
                        value = (rest:sub(i):gsub("%s+$", ""))
                        i = n + 1
                    end
                end
                result.params[key:lower()] = value
            end
        end
    end
    return result
end

local function parse_headers(block)
    local headers = {}
    local order = {}
    local last_key
    for line in block:gmatch("[^\r\n]+") do
        -- Continuation lines start with whitespace.
        if (line:sub(1, 1) == " " or line:sub(1, 1) == "\t") and last_key then
            headers[last_key] = headers[last_key] .. " " .. line:gsub("^%s+", "")
        else
            local k, v = line:match("^([^:]+):%s*(.*)$")
            if k then
                k = k:lower()
                headers[k] = v
                order[#order + 1] = k
                last_key = k
            end
        end
    end
    return headers, order
end

function M.parse_multipart(body, boundary)
    if type(body) ~= "string" then
        error("mime.parse_multipart: expected string body, got " .. type(body))
    end
    if type(boundary) ~= "string" or boundary == "" then
        error("mime.parse_multipart: boundary required")
    end
    local delim = "--" .. boundary
    local parts = {}
    -- Find first delimiter; tolerate a preamble.
    local pos = body:find(delim, 1, true)
    if not pos then return parts end
    pos = pos + #delim
    while true do
        -- Each delimiter line is followed by CRLF (or LF), unless it's the close form.
        if body:sub(pos, pos + 1) == "--" then
            return parts  -- close delimiter reached
        end
        -- Skip transport padding then CRLF.
        local lf = body:find("\n", pos, true)
        if not lf then return parts end
        pos = lf + 1
        -- Find next delimiter -- part body is between here and the next
        -- "--boundary". Use a PLAIN search (find(..., true)): real MIME/HTTP
        -- boundaries routinely contain Lua-pattern metacharacters (- . + =),
        -- so the boundary must NEVER be interpolated into a pattern. The old
        -- `find("\r?\n" .. delim, pos)` parsed the leading "--" as a lazy
        -- quantifier and mis-aligned by a byte, corrupting most real bodies.
        local nxt = body:find(delim, pos, true)
        if not nxt then
            -- No more delimiters -- malformed but salvage what's left.
            local hdr_end, hdr_end_to = body:find("\r?\n\r?\n", pos)
            if hdr_end then
                local hdr_block = body:sub(pos, hdr_end - 1)
                local headers, order = parse_headers(hdr_block)
                parts[#parts + 1] = {
                    headers = headers,
                    order   = order,
                    body    = body:sub(hdr_end_to + 1),
                }
            end
            return parts
        end
        -- The delimiter is introduced by a CRLF (or bare LF) that belongs to
        -- the boundary, not the part body; trim it off the part content.
        local body_end = nxt - 1
        if body:sub(body_end, body_end) == "\n" then body_end = body_end - 1 end
        if body:sub(body_end, body_end) == "\r" then body_end = body_end - 1 end
        local part_block = body:sub(pos, body_end)
        -- Split headers vs body on the first blank line.
        local hdr_end, hdr_end_to = part_block:find("\r?\n\r?\n")
        local headers, order, part_body
        if hdr_end then
            local hdr_block = part_block:sub(1, hdr_end - 1)
            headers, order = parse_headers(hdr_block)
            part_body = part_block:sub(hdr_end_to + 1)
        else
            headers, order = {}, {}
            part_body = part_block
        end
        parts[#parts + 1] = { headers = headers, order = order, body = part_body }
        -- Advance past the delimiter we just matched.
        pos = nxt + #delim
        -- Check whether this is a close delimiter.
        if body:sub(pos, pos + 1) == "--" then return parts end
    end
end

function M.format_multipart(parts, boundary)
    if type(parts) ~= "table" then
        error("mime.format_multipart: expected table, got " .. type(parts))
    end
    if type(boundary) ~= "string" or boundary == "" then
        error("mime.format_multipart: boundary required")
    end
    local out, n = {}, 0
    for _, part in ipairs(parts) do
        n = n + 1; out[n] = "--" .. boundary .. "\r\n"
        local headers = part.headers or {}
        local order = part.order
        if order and #order > 0 then
            for _, k in ipairs(order) do
                if headers[k] ~= nil then
                    n = n + 1; out[n] = k .. ": " .. tostring(headers[k]) .. "\r\n"
                end
            end
        else
            for k, v in pairs(headers) do
                n = n + 1; out[n] = k .. ": " .. tostring(v) .. "\r\n"
            end
        end
        n = n + 1; out[n] = "\r\n"
        n = n + 1; out[n] = part.body or ""
        n = n + 1; out[n] = "\r\n"
    end
    n = n + 1; out[n] = "--" .. boundary .. "--\r\n"
    return table.concat(out)
end

return M
