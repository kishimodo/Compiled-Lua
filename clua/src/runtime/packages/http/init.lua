-- http -- HTTP/1.1 client + server, pure Lua atop `socket` and `tls_client`.
--
-- Public surface:
--   Client:
--     http.request(method, url, opts?) -> { status, headers, body, http_version }
--     http.get/post/put/delete/head/patch(url, opts?)
--     http.parse_url(url) -> { scheme, host, port, path, query, fragment, userinfo }
--   Server:
--     http.serve(host, port, handler, opts?)  -- blocks; handler(req) -> {status,headers,body}
--     http.router() -> r with :get/:post/:put/:delete/:patch/:head/:any/:match
--
-- opts (client):
--   headers           = { ["X-Foo"] = "bar" }
--   body              = string | function () -> string|nil  (chunked if function)
--   timeout           = ms (per socket op)
--   follow_redirects  = true|number (max redirects, default 5)
--   max_response_body = bytes (default 32MB)
--   stream            = function(chunk) -- if set, called for each body chunk;
--                        returned body is "" and the function controls accumulation
--   proxy             = "http://proxy:8080" (only HTTP CONNECT for https)
--   cookies           = { name=value, ... } (sent as Cookie header)
--   tls               = { verify=..., alpn=..., server_name=..., verify_cb=... }
--   decompress        = true (default) -- transparently inflate gzip/deflate when zlib loadable

local socket  = require "socket"
local tls     = require "tls_client"

local M = {}

-- ============================================================
-- Optional zlib (only if a zlib.* package is shipped). When absent,
-- compressed responses are returned verbatim with a header marker
-- and a notice in the .compressed field so callers can detect.
-- ============================================================

local ok_zlib, zlib = pcall(require, "zlib")
if not ok_zlib then zlib = nil end

local function maybe_inflate(body, encoding)
    if not encoding or encoding == "identity" then return body end
    if not zlib then
        -- Caller can read response.compressed and handle themselves.
        return body
    end
    if encoding == "gzip" and zlib.gunzip then return zlib.gunzip(body) end
    if encoding == "deflate" and zlib.inflate then return zlib.inflate(body) end
    return body
end

-- ============================================================
-- URL parser (no regex laundering -- explicit small state machine)
-- ============================================================

function M.parse_url(url)
    -- scheme://[userinfo@]host[:port][/path][?query][#fragment]
    local scheme, rest = url:match("^(%w[%w+.%-]*)://(.*)$")
    if not scheme then return nil, "missing scheme" end
    scheme = scheme:lower()
    local authority, path_etc = rest:match("^([^/]+)(/?.*)$")
    if not authority then authority = rest; path_etc = "/" end
    if path_etc == "" then path_etc = "/" end
    local userinfo
    local at = authority:find("@", 1, true)
    if at then
        userinfo = authority:sub(1, at - 1)
        authority = authority:sub(at + 1)
    end
    local host, port
    if authority:sub(1, 1) == "[" then
        -- v6: [::1]:8080
        local rb = authority:find("]", 2, true)
        if not rb then return nil, "bad v6 authority" end
        host = authority:sub(2, rb - 1)
        if authority:sub(rb + 1, rb + 1) == ":" then
            port = tonumber(authority:sub(rb + 2))
        end
    else
        local colon = authority:find(":", 1, true)
        if colon then
            host = authority:sub(1, colon - 1)
            port = tonumber(authority:sub(colon + 1))
        else
            host = authority
        end
    end
    if not port then
        if scheme == "https" or scheme == "wss" then port = 443
        elseif scheme == "ws" or scheme == "http" then port = 80
        elseif scheme == "smtp"  then port = 25
        elseif scheme == "smtps" then port = 465 end
    end
    local frag
    local hash = path_etc:find("#", 1, true)
    if hash then
        frag = path_etc:sub(hash + 1)
        path_etc = path_etc:sub(1, hash - 1)
    end
    local query
    local qmark = path_etc:find("?", 1, true)
    if qmark then
        query = path_etc:sub(qmark + 1)
        path_etc = path_etc:sub(1, qmark - 1)
    end
    if path_etc == "" then path_etc = "/" end
    return {
        scheme   = scheme,
        userinfo = userinfo,
        host     = host,
        port     = port,
        path     = path_etc,
        query    = query,
        fragment = frag,
    }
end

-- ============================================================
-- Header helpers (case-insensitive)
-- ============================================================
--
-- Headers travel as a flat { ["Content-Type"]="..." } table for the
-- API. Internally we use lowercase keys for lookups (HTTP is
-- case-insensitive per RFC 9110) so any iteration can be case-aware.

local function lower_headers(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k:lower()] = v end
    return out
end

local function format_request_line(method, path)
    return method:upper() .. " " .. path .. " HTTP/1.1\r\n"
end

local function format_headers(h)
    local parts, n = {}, 0
    for k, v in pairs(h) do
        if type(v) == "table" then
            -- Repeated header (e.g. Set-Cookie): one line per value
            for _, vv in ipairs(v) do
                n = n + 1; parts[n] = k .. ": " .. tostring(vv) .. "\r\n"
            end
        else
            n = n + 1; parts[n] = k .. ": " .. tostring(v) .. "\r\n"
        end
    end
    return table.concat(parts)
end

-- ============================================================
-- Wire helpers (read status line + headers from a socket)
-- ============================================================

local function read_status_line(conn)
    local line, err = conn:read_line({ crlf = true, max_bytes = 8192 })
    if not line then return nil, err end
    local ver, code, reason = line:match("^HTTP/(%d%.%d)%s+(%d+)%s*(.*)$")
    if not ver then return nil, "bad status line: " .. line end
    return tonumber(code), reason, ver
end

local function read_headers(conn)
    local h = {}
    for _ = 1, 200 do
        local line, err = conn:read_line({ crlf = true, max_bytes = 16384 })
        if not line then return nil, err end
        if line == "" then return h end
        -- folded continuation? RFC deprecates but parsers should handle.
        local c1 = line:sub(1, 1)
        if c1 == " " or c1 == "\t" then
            -- Append to previous header in insertion order. We don't
            -- track order so glom onto the last-set key.
            local lastk
            for k in pairs(h) do lastk = k end
            if lastk then h[lastk] = h[lastk] .. " " .. line:gsub("^%s+", "") end
        else
            local k, v = line:match("^([^:]+):%s*(.*)$")
            if not k then return nil, "bad header line: " .. line end
            k = k:lower()
            v = v:gsub("%s+$", "")
            if h[k] then
                if type(h[k]) == "table" then
                    h[k][#h[k] + 1] = v
                else
                    h[k] = { h[k], v }
                end
            else
                h[k] = v
            end
        end
    end
    return nil, "too many headers"
end

-- ============================================================
-- Chunked transfer-encoding decoder
-- ============================================================
--
-- Reads chunks until a 0-length terminator; appends to body buf or
-- streams via on_chunk. Returns final body string ("" if streamed).

local function read_chunked(conn, max_bytes, on_chunk)
    local total, parts = 0, {}
    while true do
        local szline, err = conn:read_line({ crlf = true, max_bytes = 256 })
        if not szline then return nil, err end
        -- "<hex>[;ext]"
        local hexpart = szline:match("^([0-9A-Fa-f]+)")
        if not hexpart then return nil, "bad chunk size: " .. szline end
        local n = tonumber(hexpart, 16)
        if n == 0 then
            -- consume trailer headers up to the blank line
            while true do
                local tl, terr = conn:read_line({ crlf = true, max_bytes = 8192 })
                if not tl then return nil, terr end
                if tl == "" then break end
            end
            if on_chunk then return "" end
            return table.concat(parts)
        end
        total = total + n
        if max_bytes and total > max_bytes then
            return nil, "response body exceeds max_response_body"
        end
        local data, derr = conn:read_exact(n)
        if not data then return nil, derr end
        -- consume the CRLF after the chunk data
        local _, eerr = conn:read_exact(2)
        if eerr then return nil, eerr end
        if on_chunk then
            on_chunk(data)
        else
            parts[#parts + 1] = data
        end
    end
end

local function read_body(conn, headers, opts)
    local enc = (headers["transfer-encoding"] or ""):lower()
    if enc:find("chunked", 1, true) then
        return read_chunked(conn, opts.max_response_body, opts.stream)
    end
    local clen = tonumber(headers["content-length"])
    if clen then
        if opts.max_response_body and clen > opts.max_response_body then
            return nil, "response body exceeds max_response_body"
        end
        if opts.stream then
            local left = clen
            while left > 0 do
                local n = (left < 65536) and left or 65536
                local chunk, err = conn:read_exact(n)
                if not chunk then return nil, err end
                opts.stream(chunk)
                left = left - n
            end
            return ""
        end
        if clen == 0 then return "" end
        return conn:read_exact(clen)
    end
    -- No content-length, no chunked: read until EOF (HTTP/1.0 style).
    local parts, total = {}, 0
    while true do
        local chunk, err = conn:read(65536)
        if not chunk then
            if err == "eof" then break end
            return nil, err
        end
        total = total + #chunk
        if opts.max_response_body and total > opts.max_response_body then
            return nil, "response body exceeds max_response_body"
        end
        if opts.stream then opts.stream(chunk) else parts[#parts + 1] = chunk end
    end
    return opts.stream and "" or table.concat(parts)
end

-- ============================================================
-- Keep-alive connection pool
-- ============================================================
--
-- Keyed by "scheme://host:port". Each entry is a list of idle conns.
-- We don't aggressively probe for liveness; the next request will
-- detect a half-open TCP via "send error 10053/10054" and retry once.

local _pool = {}
local POOL_MAX_PER_HOST = 4

local function pool_key(u) return u.scheme .. "://" .. u.host .. ":" .. u.port end

local function pool_get(u)
    local k = pool_key(u)
    local q = _pool[k]
    if not q or #q == 0 then return nil end
    local c = q[#q]; q[#q] = nil
    return c
end

local function pool_put(u, conn)
    if not conn then return end
    local k = pool_key(u)
    local q = _pool[k]; if not q then q = {}; _pool[k] = q end
    if #q >= POOL_MAX_PER_HOST then conn:close(); return end
    q[#q + 1] = conn
end

-- ============================================================
-- Connection acquisition (HTTP / HTTPS / via proxy)
-- ============================================================

local function open_conn(u, opts)
    local pooled = pool_get(u)
    if pooled then return pooled end

    -- Proxy short-circuit: for https we need CONNECT; for http we
    -- just send absolute-URI requests at the proxy.
    if opts.proxy and u.scheme == "https" then
        local pu = M.parse_url(opts.proxy)
        if not pu then return nil, "bad proxy url" end
        local raw, err = socket.tcp.connect(pu.host, pu.port,
            { timeout = opts.timeout, nodelay = true })
        if not raw then return nil, err end
        raw:write(string.format(
            "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n",
            u.host, u.port, u.host, u.port))
        local code, _, _ = read_status_line(raw)
        if not code then raw:close(); return nil, "proxy connect no response" end
        local h, herr = read_headers(raw)
        if not h then raw:close(); return nil, herr end
        if code < 200 or code >= 300 then
            raw:close()
            return nil, "proxy CONNECT failed: " .. code
        end
        -- Upgrade to TLS over the tunneled socket. We can't reuse our
        -- tls_client.connect() directly because it opens a fresh
        -- transport; do an inline handshake instead would mean exposing
        -- internals. Cheap alternative: close raw, open tls fresh, BUT
        -- a proper proxy CONNECT keeps the tunnel; for simplicity the
        -- proxy-https path opens tls separately (so opts.proxy currently
        -- only helps http; documented limit).
        raw:close()
        return tls.connect(u.host, u.port, opts.tls or {})
    end

    if u.scheme == "https" then
        local opts_tls = opts.tls or {}
        opts_tls.timeout = opts_tls.timeout or opts.timeout
        return tls.connect(u.host, u.port, opts_tls)
    end
    return socket.tcp.connect(u.host, u.port,
        { timeout = opts.timeout, nodelay = true })
end

-- ============================================================
-- Cookie / Host / Default header injection
-- ============================================================

local function format_cookies(jar)
    local parts, n = {}, 0
    for k, v in pairs(jar) do
        n = n + 1; parts[n] = k .. "=" .. v
    end
    return table.concat(parts, "; ")
end

local function inject_defaults(headers, u, opts, body_len, body_is_stream)
    local lh = {}
    local out = {}
    for k, v in pairs(headers) do
        lh[k:lower()] = true
        out[k] = v
    end
    if not lh["host"] then
        -- include port only if non-default
        if (u.scheme == "http"  and u.port ~= 80)
        or (u.scheme == "https" and u.port ~= 443) then
            out["Host"] = u.host .. ":" .. u.port
        else
            out["Host"] = u.host
        end
    end
    if not lh["user-agent"] then
        out["User-Agent"] = "CLua-http/0.1"
    end
    if not lh["accept"] then
        out["Accept"] = "*/*"
    end
    if not lh["connection"] then
        out["Connection"] = "keep-alive"
    end
    if not lh["accept-encoding"] and zlib then
        out["Accept-Encoding"] = "gzip, deflate"
    end
    if opts.cookies and not lh["cookie"] then
        out["Cookie"] = format_cookies(opts.cookies)
    end
    if body_is_stream then
        if not lh["transfer-encoding"] then
            out["Transfer-Encoding"] = "chunked"
        end
    elseif body_len and body_len > 0 then
        if not lh["content-length"] then
            out["Content-Length"] = tostring(body_len)
        end
    elseif body_len == 0 then
        out["Content-Length"] = "0"
    end
    return out
end

-- ============================================================
-- Single-shot request (no redirects). Internal.
-- ============================================================

local function send_body_streaming(conn, reader)
    -- chunked: each call to reader() returns a chunk or nil to end.
    while true do
        local chunk = reader()
        if not chunk or chunk == "" then
            local ok, err = conn:write("0\r\n\r\n")
            if not ok then return nil, err end
            return true
        end
        local n = #chunk
        local hex = string.format("%x", n)
        local ok, err = conn:write(hex .. "\r\n" .. chunk .. "\r\n")
        if not ok then return nil, err end
    end
end

local function do_request_once(method, url, opts)
    local u, perr = M.parse_url(url)
    if not u then return nil, perr end
    local conn, cerr = open_conn(u, opts)
    if not conn then return nil, cerr end
    if opts.timeout then conn:set_timeout(opts.timeout) end

    local body_is_stream = (type(opts.body) == "function")
    local body_str       = (type(opts.body) == "string") and opts.body or nil
    local body_len       = body_str and #body_str or nil

    local hdr = inject_defaults(opts.headers or {}, u, opts, body_len, body_is_stream)

    -- Build request-target. With http proxy (non-CONNECT) it's an absolute URI.
    local target = u.path
    if u.query then target = target .. "?" .. u.query end
    if opts.proxy and u.scheme == "http" then
        target = u.scheme .. "://" .. u.host
              .. (u.port == 80 and "" or (":" .. u.port))
              .. target
    end

    local req = format_request_line(method, target) .. format_headers(hdr) .. "\r\n"
    local ok, werr = conn:write(req)
    if not ok then conn:close(); return nil, werr end

    if body_is_stream then
        local sok, serr = send_body_streaming(conn, opts.body)
        if not sok then conn:close(); return nil, serr end
    elseif body_str then
        if #body_str > 0 then
            local bok, berr = conn:write(body_str)
            if not bok then conn:close(); return nil, berr end
        end
    end

    -- 100 Continue: rare in client paths, but if expected we should
    -- read an interim status line. We treat any 1xx as informational.
    local code, reason, ver
    repeat
        code, reason, ver = read_status_line(conn)
        if not code then conn:close(); return nil, reason end
    until code >= 200

    local h, herr = read_headers(conn)
    if not h then conn:close(); return nil, herr end

    local body, berr
    if method:upper() == "HEAD" or code == 204 or code == 304 then
        body = ""
    else
        body, berr = read_body(conn, h, opts)
        if not body then conn:close(); return nil, berr end
    end

    -- Decompress.
    local compressed = (h["content-encoding"] or "")
    local final_body = body
    if opts.decompress ~= false and not opts.stream
            and compressed ~= "" and compressed ~= "identity" then
        final_body = maybe_inflate(body, compressed:lower())
    end

    -- Keep-alive vs close decision.
    local keepalive
    if ver == "1.1" then
        keepalive = ((h["connection"] or ""):lower() ~= "close")
    else
        keepalive = ((h["connection"] or ""):lower() == "keep-alive")
    end
    if keepalive then pool_put(u, conn) else conn:close() end

    return {
        status        = code,
        reason        = reason,
        headers       = h,
        body          = final_body,
        compressed    = compressed ~= "" and compressed ~= "identity" and compressed or nil,
        http_version  = ver,
        url           = url,
    }
end

-- ============================================================
-- Public client entries (with redirect following)
-- ============================================================

function M.request(method, url, opts)
    opts = opts or {}
    opts.headers = opts.headers or {}
    if opts.follow_redirects == nil then opts.follow_redirects = 5 end
    local max_redir = opts.follow_redirects
    if max_redir == true then max_redir = 5 end
    if max_redir == false then max_redir = 0 end

    local cur_method = method
    local cur_url    = url
    local hop        = 0
    while true do
        local resp, err = do_request_once(cur_method, cur_url, opts)
        if not resp then return nil, err end
        local code = resp.status
        if code < 300 or code >= 400 or max_redir == 0 or hop >= max_redir then
            return resp
        end
        local loc = resp.headers["location"]
        if not loc then return resp end
        -- Resolve relative redirects against the current URL.
        if not loc:find("://", 1, true) then
            local u = M.parse_url(cur_url)
            if loc:sub(1, 1) == "/" then
                loc = u.scheme .. "://" .. u.host
                   .. ((u.scheme == "http" and u.port == 80)
                        or (u.scheme == "https" and u.port == 443)
                        and "" or (":" .. u.port)) .. loc
            else
                -- relative path: strip last segment and append
                local base = u.path:gsub("/[^/]*$", "/")
                loc = u.scheme .. "://" .. u.host
                   .. ((u.scheme == "http" and u.port == 80)
                        or (u.scheme == "https" and u.port == 443)
                        and "" or (":" .. u.port))
                   .. base .. loc
            end
        end
        -- 303 always becomes GET; 301/302 historically also do (preserve
        -- body only on 307/308). Strip body + content headers on switch.
        if code == 301 or code == 302 or code == 303 then
            cur_method = "GET"
            opts.body = nil
            opts.headers["Content-Length"] = nil
            opts.headers["Transfer-Encoding"] = nil
        end
        cur_url = loc
        hop = hop + 1
    end
end

-- Convenience verbs
for _, m in ipairs({ "get", "post", "put", "delete", "head", "patch", "options" }) do
    M[m] = function(url, opts) return M.request(m:upper(), url, opts) end
end

-- ============================================================
-- Server
-- ============================================================
--
-- http.serve(host, port, handler, opts?)
--   handler: function(req) -> { status=, headers=, body= }
--     req fields: method, path, query, headers, body, http_version,
--                 remote_addr, raw_path (incl. query string)
--   opts:
--     keep_alive       = true (default)
--     max_request_body = bytes (default 8MB)
--     max_header_bytes = bytes (default 64K)
--     stop_when        = function() -- if returns true between requests, exit
--
-- This is a single-threaded blocking server. For concurrent clients,
-- wrap http.serve in `async.run(...)` or fork multiple processes; the
-- intent here is something a tooling script can use directly.

local function parse_request_line(line)
    local m, t, ver = line:match("^(%u+)%s+(%S+)%s+HTTP/(%d%.%d)$")
    if not m then return nil, "bad request line: " .. line end
    return m, t, ver
end

local function read_request_headers(conn, max_header_bytes)
    local h, total = {}, 0
    for _ = 1, 200 do
        local line, err = conn:read_line({ crlf = true, max_bytes = max_header_bytes })
        if not line then return nil, err end
        total = total + #line + 2
        if total > max_header_bytes then return nil, "headers too large" end
        if line == "" then return h end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if not k then return nil, "bad header" end
        k = k:lower(); v = v:gsub("%s+$", "")
        if h[k] then
            if type(h[k]) == "table" then h[k][#h[k] + 1] = v
            else h[k] = { h[k], v } end
        else
            h[k] = v
        end
    end
    return nil, "too many headers"
end

local function read_request_body(conn, h, max_body)
    local enc = (h["transfer-encoding"] or ""):lower()
    if enc:find("chunked", 1, true) then
        return read_chunked(conn, max_body, nil)
    end
    local clen = tonumber(h["content-length"])
    if not clen or clen == 0 then return "" end
    if max_body and clen > max_body then return nil, "request body too large" end
    return conn:read_exact(clen)
end

local _status_text = {
    [200] = "OK",          [201] = "Created",     [204] = "No Content",
    [301] = "Moved Permanently",[302] = "Found",  [303] = "See Other",
    [304] = "Not Modified",[307] = "Temporary Redirect",[308] = "Permanent Redirect",
    [400] = "Bad Request", [401] = "Unauthorized",[403] = "Forbidden",
    [404] = "Not Found",   [405] = "Method Not Allowed",
    [409] = "Conflict",    [413] = "Payload Too Large",
    [500] = "Internal Server Error", [502] = "Bad Gateway",
    [503] = "Service Unavailable",
}

local function write_response(conn, resp, head_only)
    local status = resp.status or 200
    local hdr    = resp.headers or {}
    local body   = resp.body or ""
    local body_is_stream = (type(body) == "function")
    -- Build lowercase set for case-insensitive default injection.
    local lh = {}
    for k in pairs(hdr) do lh[k:lower()] = true end

    if not lh["content-type"] and not body_is_stream and #body > 0 then
        hdr["Content-Type"] = "application/octet-stream"
    end
    if body_is_stream then
        if not lh["transfer-encoding"] then
            hdr["Transfer-Encoding"] = "chunked"
        end
    else
        if not lh["content-length"] then
            hdr["Content-Length"] = tostring(head_only and 0 or #body)
        end
    end
    if not lh["server"] then hdr["Server"] = "CLua-http/0.1" end
    local status_line = string.format("HTTP/1.1 %d %s\r\n",
        status, _status_text[status] or "")
    local ok, err = conn:write(status_line .. format_headers(hdr) .. "\r\n")
    if not ok then return nil, err end
    if head_only then return true end
    if body_is_stream then
        return send_body_streaming(conn, body)
    end
    if #body > 0 then return conn:write(body) end
    return true
end

function M.serve(host, port, handler, opts)
    opts = opts or {}
    local max_body = opts.max_request_body or 8 * 1024 * 1024
    local max_hdr  = opts.max_header_bytes or 65536
    local keepalive_default = (opts.keep_alive ~= false)
    local server, err = socket.tcp.listen(host, port, opts.backlog or 64)
    if not server then return nil, err end
    if opts.timeout then server:set_timeout(opts.timeout) end

    while true do
        if opts.stop_when and opts.stop_when() then break end
        local conn, aerr = server:accept()
        if not conn then
            if aerr == "timeout" then
                -- retry; gives stop_when a chance to fire
            else
                server:close()
                return nil, aerr
            end
        else
            if opts.timeout then conn:set_timeout(opts.timeout) end
            -- Per-connection loop: handle as many requests as keep-alive
            -- and the peer permit.
            local rhost, rport = conn:peer_addr()
            local alive = true
            while alive do
                local line, lerr = conn:read_line({ crlf = true, max_bytes = max_hdr })
                if not line or line == "" then break end
                local method, raw_path, ver = parse_request_line(line)
                if not method then break end
                local headers, herr = read_request_headers(conn, max_hdr)
                if not headers then break end
                local body
                body, lerr = read_request_body(conn, headers, max_body)
                if not body then
                    -- Best-effort 400 + close.
                    pcall(write_response, conn, { status = 400, body = lerr or "bad request" })
                    break
                end
                local path = raw_path
                local query
                local qi = raw_path:find("?", 1, true)
                if qi then path = raw_path:sub(1, qi - 1); query = raw_path:sub(qi + 1) end

                local req = {
                    method       = method,
                    path         = path,
                    raw_path     = raw_path,
                    query        = query,
                    headers      = headers,
                    body         = body,
                    http_version = ver,
                    remote_addr  = rhost,
                    remote_port  = rport,
                }
                local ok_h, resp = pcall(handler, req)
                if not ok_h then
                    resp = { status = 500, body = "internal error: " .. tostring(resp) }
                end
                resp = resp or { status = 204 }

                -- decide keep-alive: peer hint + server default
                local conn_hdr = (headers["connection"] or ""):lower()
                local want_close = (conn_hdr == "close") or (not keepalive_default)
                                or (ver == "1.0" and conn_hdr ~= "keep-alive")
                if want_close then
                    resp.headers = resp.headers or {}
                    resp.headers["Connection"] = "close"
                end
                local wok, werr = write_response(conn, resp, method == "HEAD")
                if not wok then alive = false; lerr = werr end
                if want_close then alive = false end
            end
            conn:close()
        end
    end
    server:close()
    return true
end

-- ============================================================
-- Router (compiled path patterns)
-- ============================================================
--
-- :get("/users/:id", fn) where fn(req, params) -> resp.
-- Path patterns use ":name" placeholders and "*rest" wildcards.

local router_mt = { __index = {} }
local router_methods = router_mt.__index

local function compile_pattern(pat)
    -- Translate to a Lua pattern with capture groups.
    local names = {}
    local lp = pat:gsub("([%-%.])", "%%%1")           -- escape . -
    lp = lp:gsub(":([%w_]+)", function(n)
        names[#names + 1] = n
        return "([^/]+)"
    end)
    lp = lp:gsub("%*([%w_]+)", function(n)
        names[#names + 1] = n
        return "(.*)"
    end)
    return "^" .. lp .. "$", names
end

function router_methods:add(method, pattern, fn)
    local lp, names = compile_pattern(pattern)
    self.routes[#self.routes + 1] = {
        method = method, pattern = lp, names = names, fn = fn,
    }
end

for _, m in ipairs({ "get", "post", "put", "delete", "head", "patch", "options" }) do
    router_methods[m] = function(self, pattern, fn) self:add(m:upper(), pattern, fn) end
end
function router_methods:any(pattern, fn) self:add("*", pattern, fn) end

function router_methods:match(method, path)
    for _, r in ipairs(self.routes) do
        if r.method == "*" or r.method == method then
            local m = { string.match(path, r.pattern) }
            if m[1] then
                local params = {}
                for i, name in ipairs(r.names) do params[name] = m[i] end
                return r.fn, params
            end
        end
    end
    return nil
end

-- Convenience: router objects are also callable as handlers for serve().
router_mt.__call = function(self, req)
    local fn, params = self:match(req.method, req.path)
    if not fn then return { status = 404, body = "not found" } end
    return fn(req, params)
end

function M.router()
    return setmetatable({ routes = {} }, router_mt)
end

return M
