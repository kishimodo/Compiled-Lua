-- websocket -- RFC 6455 client + server with permessage-deflate (RFC 7692).
--
-- Public surface:
--   Client:
--     websocket.connect(url, opts?) -> ws
--     ws:send(msg, kind?)             kind = "text" (default) | "binary"
--     ws:recv()                       -> msg, kind | nil, err
--     ws:close(code?, reason?)
--     ws:ping(payload?)
--     ws:pong(payload?)
--     ws:set_timeout(ms)
--
--   Server:
--     websocket.upgrade(req, conn, handler) -- inside an http handler;
--       handler(ws) runs the per-connection loop. conn is the http
--       server's raw `socket` conn passed via opts.
--     websocket.serve(host, port, handler, opts?) -- standalone server
--       that runs http underneath and hands off Upgrade requests.
--
-- opts:
--   subprotocols   = { "chat", "json" }   -- Sec-WebSocket-Protocol
--   permessage_deflate = true/false       -- default true if zlib loaded
--   max_message_size   = bytes (default 16MB)
--   headers        = extra request headers
--   tls            = { verify=..., alpn=..., ... } for wss
--   timeout        = ms

local ffi    = ffi
require "windows"
local socket = require "socket"
local tls    = require "tls_client"
local http   = require "http"

local ok_zlib, zlib = pcall(require, "zlib")
if not ok_zlib then zlib = nil end

local M = {}

-- ============================================================
-- Low-level SHA-1 via BCrypt (needed for Sec-WebSocket-Accept)
-- ============================================================
-- We avoid pulling in the whole hash package since it isn't always
-- installed; the SHA-1 surface is small enough to inline.

ffi.cdef[[
NTSTATUS BCryptOpenAlgorithmProvider(PVOID *, LPCWSTR, LPCWSTR, ULONG);
NTSTATUS BCryptCloseAlgorithmProvider(PVOID, ULONG);
NTSTATUS BCryptCreateHash(PVOID, PVOID *, PVOID, ULONG, PVOID, ULONG, ULONG);
NTSTATUS BCryptHashData(PVOID, PVOID, ULONG, ULONG);
NTSTATUS BCryptFinishHash(PVOID, PVOID, ULONG, ULONG);
NTSTATUS BCryptDestroyHash(PVOID);
NTSTATUS BCryptGenRandom(PVOID, PVOID, ULONG, ULONG);
]]
pcall(ffi.load, "bcrypt")

local function utf8_to_wide(s)
    local n = #s
    local buf = ffi.new("unsigned short[?]", n + 1)
    for i = 1, n do buf[i - 1] = s:byte(i) end
    buf[n] = 0
    return buf
end

local _sha1_alg
local function sha1(input)
    if not _sha1_alg then
        local h = ffi.new("PVOID[1]")
        if ffi.C.BCryptOpenAlgorithmProvider(h, utf8_to_wide("SHA1"), nil, 0) ~= 0 then
            error("websocket: BCryptOpenAlgorithmProvider(SHA1) failed")
        end
        _sha1_alg = h[0]
    end
    local hash = ffi.new("PVOID[1]")
    if ffi.C.BCryptCreateHash(_sha1_alg, hash, nil, 0, nil, 0, 0) ~= 0 then
        error("websocket: BCryptCreateHash failed")
    end
    local h = hash[0]
    if ffi.C.BCryptHashData(h, ffi.cast("PVOID", input), #input, 0) ~= 0 then
        ffi.C.BCryptDestroyHash(h)
        error("websocket: BCryptHashData failed")
    end
    local out = ffi.new("unsigned char[20]")
    if ffi.C.BCryptFinishHash(h, out, 20, 0) ~= 0 then
        ffi.C.BCryptDestroyHash(h)
        error("websocket: BCryptFinishHash failed")
    end
    ffi.C.BCryptDestroyHash(h)
    return ffi.string(out, 20)
end

local function bcrypt_random(n)
    local out = ffi.new("unsigned char[?]", n)
    if ffi.C.BCryptGenRandom(nil, out, n,
            0x00000002 --[[BCRYPT_USE_SYSTEM_PREFERRED_RNG]]) ~= 0 then
        error("websocket: BCryptGenRandom failed")
    end
    return ffi.string(out, n)
end

-- Base64 (small inline -- websocket only needs the encode side for the
-- accept-key handshake; no need to depend on base64 package).
local _b64_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(s)
    local out, n = {}, 0
    local len = #s
    local i = 1
    while i + 2 <= len do
        local a, b, c = s:byte(i), s:byte(i + 1), s:byte(i + 2)
        local v = (a << 16) | (b << 8) | c
        n = n + 1; out[n] = _b64_alpha:sub((v >> 18) + 1, (v >> 18) + 1)
                           .. _b64_alpha:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
                           .. _b64_alpha:sub(((v >>  6) & 63) + 1, ((v >>  6) & 63) + 1)
                           .. _b64_alpha:sub(((v      ) & 63) + 1, ((v      ) & 63) + 1)
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local a = s:byte(i)
        local v = a << 16
        n = n + 1; out[n] = _b64_alpha:sub((v >> 18) + 1, (v >> 18) + 1)
                           .. _b64_alpha:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
                           .. "=="
    elseif rem == 2 then
        local a, b = s:byte(i), s:byte(i + 1)
        local v = (a << 16) | (b << 8)
        n = n + 1; out[n] = _b64_alpha:sub((v >> 18) + 1, (v >> 18) + 1)
                           .. _b64_alpha:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
                           .. _b64_alpha:sub(((v >>  6) & 63) + 1, ((v >>  6) & 63) + 1)
                           .. "="
    end
    return table.concat(out)
end

-- ============================================================
-- RFC 6455 framing
-- ============================================================
-- Opcodes
local OP_CONT     = 0x0
local OP_TEXT     = 0x1
local OP_BINARY   = 0x2
local OP_CLOSE    = 0x8
local OP_PING     = 0x9
local OP_PONG     = 0xA

local WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function pack_u16(n) return string.char((n >> 8) & 0xFF, n & 0xFF) end
local function pack_u64(n)
    local out = {}
    for i = 7, 0, -1 do out[#out + 1] = string.char((n >> (i * 8)) & 0xFF) end
    return table.concat(out)
end

-- Mask/unmask a payload in place with a 4-byte XOR key.
local function ws_mask(data, key)
    local out = {}
    local k1, k2, k3, k4 = key:byte(1), key:byte(2), key:byte(3), key:byte(4)
    for i = 1, #data do
        local m
        local r = (i - 1) & 3
        if     r == 0 then m = k1
        elseif r == 1 then m = k2
        elseif r == 2 then m = k3
        else                m = k4 end
        out[i] = string.char(data:byte(i) ~ m)
    end
    return table.concat(out)
end

-- Build a single frame.
local function build_frame(opcode, payload, masked, fin, rsv1)
    local b1 = (fin ~= false and 0x80 or 0) | (rsv1 and 0x40 or 0) | (opcode & 0x0F)
    local len = #payload
    local hdr
    if len < 126 then
        hdr = string.char(b1, (masked and 0x80 or 0) | len)
    elseif len < 65536 then
        hdr = string.char(b1, (masked and 0x80 or 0) | 126) .. pack_u16(len)
    else
        hdr = string.char(b1, (masked and 0x80 or 0) | 127) .. pack_u64(len)
    end
    if masked then
        local key = bcrypt_random(4)
        return hdr .. key .. ws_mask(payload, key)
    end
    return hdr .. payload
end

-- Parse a single frame header from the wire and read its payload.
local function read_frame(conn)
    local hdr, err = conn:read_exact(2)
    if not hdr then return nil, err end
    local b1, b2 = hdr:byte(1), hdr:byte(2)
    local fin    = (b1 & 0x80) ~= 0
    local rsv1   = (b1 & 0x40) ~= 0
    local opcode = b1 & 0x0F
    local masked = (b2 & 0x80) ~= 0
    local plen   = b2 & 0x7F
    if plen == 126 then
        local ext, eerr = conn:read_exact(2)
        if not ext then return nil, eerr end
        plen = (ext:byte(1) << 8) | ext:byte(2)
    elseif plen == 127 then
        local ext, eerr = conn:read_exact(8)
        if not ext then return nil, eerr end
        plen = 0
        for i = 1, 8 do plen = (plen << 8) | ext:byte(i) end
    end
    local key
    if masked then
        key, err = conn:read_exact(4)
        if not key then return nil, err end
    end
    local payload = ""
    if plen > 0 then
        payload, err = conn:read_exact(plen)
        if not payload then return nil, err end
        if masked then payload = ws_mask(payload, key) end
    end
    return {
        fin     = fin,
        rsv1    = rsv1,
        opcode  = opcode,
        masked  = masked,
        payload = payload,
    }
end

-- ============================================================
-- permessage-deflate (RFC 7692)
-- ============================================================
-- Each message is raw deflate (no zlib header). Encoded message must
-- be followed by 0x00 0x00 0xFF 0xFF removal on decompress (the
-- BFINAL=0/BTYPE=00 empty stored block flush marker). Encoders add
-- that suffix on context-takeover frames.

local function inflate_message(data)
    if not zlib then return nil, "permessage-deflate received but no zlib package" end
    -- Standard requires we APPEND 0x00 0x00 0xFF 0xFF before raw inflate.
    local raw = data .. "\x00\x00\xFF\xFF"
    if zlib.raw_inflate then return zlib.raw_inflate(raw) end
    if zlib.inflate     then return zlib.inflate(raw, -15) end
    return nil, "zlib package lacks raw_inflate"
end

local function deflate_message(data)
    if not zlib then return nil, "permessage-deflate requested but no zlib package" end
    local out
    if zlib.raw_deflate then out = zlib.raw_deflate(data)
    elseif zlib.deflate then out = zlib.deflate(data, -15)
    else return nil, "zlib package lacks raw_deflate" end
    -- Strip trailing 0x00 0x00 0xFF 0xFF per spec.
    if out:sub(-4) == "\x00\x00\xFF\xFF" then out = out:sub(1, -5) end
    return out
end

-- ============================================================
-- WS object
-- ============================================================

local ws_mt = { __index = {} }
local ws_methods = ws_mt.__index

function ws_methods:set_timeout(ms) self.conn:set_timeout(ms) end

function ws_methods:_write_frame(opcode, payload, opts)
    opts = opts or {}
    local rsv1 = opts.compressed and true or false
    local data = build_frame(opcode, payload, self.client_side, opts.fin, rsv1)
    return self.conn:write(data)
end

-- Send a complete message. kind: "text" (default) | "binary".
-- We always send a single FIN frame; chunked send isn't useful at this
-- API level (callers pre-built their message anyway).
function ws_methods:send(msg, kind)
    if self._closed then return nil, "ws closed" end
    local opcode = (kind == "binary") and OP_BINARY or OP_TEXT
    local payload = msg
    local compressed = false
    if self.pmd and #msg > 64 then
        -- Only compress messages with enough body to amortize header.
        local def, derr = deflate_message(msg)
        if def then payload = def; compressed = true end
    end
    return self:_write_frame(opcode, payload,
        { fin = true, compressed = compressed })
end

function ws_methods:ping(payload)
    return self:_write_frame(OP_PING, payload or "", { fin = true })
end
function ws_methods:pong(payload)
    return self:_write_frame(OP_PONG, payload or "", { fin = true })
end

function ws_methods:close(code, reason)
    if self._closed then return end
    self._closed = true
    local payload = ""
    if code then
        payload = string.char((code >> 8) & 0xFF, code & 0xFF) .. (reason or "")
    end
    pcall(function() self:_write_frame(OP_CLOSE, payload, { fin = true }) end)
    self.conn:close()
end

-- Receive one application message (text/binary). Handles ping/pong
-- transparently (auto-pongs pings), reassembles continuation frames,
-- decompresses if permessage-deflate marked it (RSV1 on first frame).
function ws_methods:recv()
    if self._closed then return nil, "ws closed" end
    local parts, opcode, compressed = nil, nil, false
    while true do
        local f, err = read_frame(self.conn)
        if not f then return nil, err end

        -- Control frames are always single-frame and short (<=125).
        if f.opcode == OP_CLOSE then
            self._closed = true
            -- Echo close frame back per RFC, then tear down.
            pcall(function() self:_write_frame(OP_CLOSE, f.payload, { fin = true }) end)
            self.conn:close()
            return nil, "closed"
        elseif f.opcode == OP_PING then
            self:_write_frame(OP_PONG, f.payload, { fin = true })
        elseif f.opcode == OP_PONG then
            -- Drop; callers don't need pong delivery (use ping/pong for
            -- keepalive only).
        elseif f.opcode == OP_TEXT or f.opcode == OP_BINARY then
            if parts then
                return nil, "new data frame mid-continuation"
            end
            opcode = f.opcode
            compressed = f.rsv1
            if f.fin then
                local body = f.payload
                if compressed then
                    local d, derr = inflate_message(body)
                    if not d then return nil, derr end
                    body = d
                end
                if self.max_message_size and #body > self.max_message_size then
                    return nil, "message exceeds max_message_size"
                end
                return body, (opcode == OP_TEXT) and "text" or "binary"
            else
                parts = { f.payload }
            end
        elseif f.opcode == OP_CONT then
            if not parts then return nil, "unexpected continuation frame" end
            parts[#parts + 1] = f.payload
            if f.fin then
                local body = table.concat(parts)
                if compressed then
                    local d, derr = inflate_message(body)
                    if not d then return nil, derr end
                    body = d
                end
                if self.max_message_size and #body > self.max_message_size then
                    return nil, "message exceeds max_message_size"
                end
                return body, (opcode == OP_TEXT) and "text" or "binary"
            end
        else
            return nil, "unknown opcode " .. f.opcode
        end
    end
end

-- ============================================================
-- Client handshake
-- ============================================================

function M.connect(url, opts)
    opts = opts or {}
    local u, perr = http.parse_url(url)
    if not u then return nil, perr end
    if u.scheme ~= "ws" and u.scheme ~= "wss" then
        return nil, "websocket: scheme must be ws or wss"
    end

    -- Open transport (raw TCP for ws, TLS for wss).
    local conn, cerr
    if u.scheme == "wss" then
        conn, cerr = tls.connect(u.host, u.port, opts.tls or { timeout = opts.timeout })
    else
        conn, cerr = socket.tcp.connect(u.host, u.port,
            { nodelay = true, timeout = opts.timeout })
    end
    if not conn then return nil, cerr end

    -- Per RFC 6455 4.1: random 16-byte key, base64 encoded.
    local key_bytes = bcrypt_random(16)
    local key_b64   = b64encode(key_bytes)

    local target = u.path
    if u.query then target = target .. "?" .. u.query end

    -- Build request headers. Default to permessage-deflate unless caller
    -- explicitly opted out OR zlib isn't available.
    local pmd_offer = (opts.permessage_deflate ~= false) and zlib
    local headers = {
        ["Host"]                  = u.host .. ((u.port == 80 or u.port == 443) and "" or (":" .. u.port)),
        ["Upgrade"]               = "websocket",
        ["Connection"]            = "Upgrade",
        ["Sec-WebSocket-Key"]     = key_b64,
        ["Sec-WebSocket-Version"] = "13",
        ["User-Agent"]            = "LuaVM-websocket/0.1",
    }
    if opts.subprotocols then
        headers["Sec-WebSocket-Protocol"] = table.concat(opts.subprotocols, ", ")
    end
    if pmd_offer then
        headers["Sec-WebSocket-Extensions"] = "permessage-deflate; client_no_context_takeover; server_no_context_takeover"
    end
    if opts.headers then
        for k, v in pairs(opts.headers) do headers[k] = v end
    end

    local req = "GET " .. target .. " HTTP/1.1\r\n"
    for k, v in pairs(headers) do req = req .. k .. ": " .. tostring(v) .. "\r\n" end
    req = req .. "\r\n"
    local ok, werr = conn:write(req)
    if not ok then conn:close(); return nil, werr end

    -- Parse response status + headers.
    local status_line, slerr = conn:read_line({ crlf = true })
    if not status_line then conn:close(); return nil, slerr end
    local code = status_line:match("^HTTP/%d%.%d%s+(%d+)")
    if not code or code ~= "101" then
        conn:close(); return nil, "handshake failed: " .. status_line
    end
    local resp_headers = {}
    while true do
        local line, lerr = conn:read_line({ crlf = true })
        if not line then conn:close(); return nil, lerr end
        if line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then resp_headers[k:lower()] = v:gsub("%s+$", "") end
    end

    -- Verify Sec-WebSocket-Accept = base64(sha1(key + magic)).
    local expected = b64encode(sha1(key_b64 .. WS_MAGIC))
    if resp_headers["sec-websocket-accept"] ~= expected then
        conn:close()
        return nil, "websocket: server accept-key mismatch"
    end

    local pmd_accepted = false
    if pmd_offer and resp_headers["sec-websocket-extensions"] then
        pmd_accepted = resp_headers["sec-websocket-extensions"]:find("permessage-deflate", 1, true) ~= nil
    end

    return setmetatable({
        conn               = conn,
        client_side        = true,    -- masks outgoing frames per RFC
        pmd                = pmd_accepted,
        _closed            = false,
        max_message_size   = opts.max_message_size or 16 * 1024 * 1024,
        subprotocol        = resp_headers["sec-websocket-protocol"],
    }, ws_mt)
end

-- ============================================================
-- Server-side upgrade
-- ============================================================
--
-- websocket.upgrade(req, conn, handler):
--   * req: parsed http req (from http.serve handler arg)
--   * conn: the raw `socket` connection that's mid-request -- you get
--           this by running the websocket server yourself (or by
--           subclassing http.serve). For convenience, websocket.serve
--           wraps that wiring.
--   * handler: function(ws) -> none; runs until ws closes.

local function make_server_ws(conn, headers, opts)
    -- Decide permessage-deflate based on client offer.
    local pmd = false
    local ext = (headers["sec-websocket-extensions"] or ""):lower()
    if zlib and ext:find("permessage-deflate", 1, true) then pmd = true end

    return setmetatable({
        conn             = conn,
        client_side      = false,
        pmd              = pmd,
        _closed          = false,
        max_message_size = opts and opts.max_message_size or 16 * 1024 * 1024,
    }, ws_mt), pmd
end

function M.upgrade(req, conn, handler, opts)
    -- Validate handshake fields.
    local h = req.headers
    if (h["upgrade"] or ""):lower() ~= "websocket" then
        conn:write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        return nil, "not a websocket upgrade"
    end
    local key = h["sec-websocket-key"]
    if not key then
        conn:write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        return nil, "missing Sec-WebSocket-Key"
    end
    local accept = b64encode(sha1(key .. WS_MAGIC))

    -- Subprotocol negotiation: pick first offered that we know.
    local protocol
    local offered = h["sec-websocket-protocol"]
    if offered and opts and opts.subprotocols then
        local set = {}
        for _, sp in ipairs(opts.subprotocols) do set[sp] = true end
        for tok in offered:gmatch("[^,%s]+") do
            if set[tok] then protocol = tok; break end
        end
    end

    local ws, pmd = make_server_ws(conn, h, opts)
    -- Build response
    local resp = "HTTP/1.1 101 Switching Protocols\r\n"
              .. "Upgrade: websocket\r\n"
              .. "Connection: Upgrade\r\n"
              .. "Sec-WebSocket-Accept: " .. accept .. "\r\n"
    if pmd then
        resp = resp .. "Sec-WebSocket-Extensions: permessage-deflate; "
                    .. "server_no_context_takeover; client_no_context_takeover\r\n"
    end
    if protocol then
        resp = resp .. "Sec-WebSocket-Protocol: " .. protocol .. "\r\n"
    end
    resp = resp .. "\r\n"
    local ok, werr = conn:write(resp)
    if not ok then return nil, werr end

    handler(ws)
    ws:close()
    return true
end

-- A self-contained server. Reuses http's request parsing for the
-- handshake but bypasses http.serve (which would write a response and
-- close the connection). Instead we accept(), read headers ourselves,
-- and hand the raw conn to upgrade().
function M.serve(host, port, handler, opts)
    opts = opts or {}
    local server, err = socket.tcp.listen(host, port, opts.backlog or 32)
    if not server then return nil, err end

    while true do
        if opts.stop_when and opts.stop_when() then break end
        local conn, aerr = server:accept()
        if not conn then
            if aerr == "timeout" then
                -- give stop_when a chance, loop
            else
                server:close()
                return nil, aerr
            end
        else
            -- Read request line + headers.
            local line = conn:read_line({ crlf = true, max_bytes = 8192 })
            if not line then conn:close()
            else
                local method, path = line:match("^(%u+)%s+(%S+)")
                if method ~= "GET" then
                    conn:write("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
                    conn:close()
                else
                    local headers = {}
                    while true do
                        local hl = conn:read_line({ crlf = true, max_bytes = 16384 })
                        if not hl or hl == "" then break end
                        local k, v = hl:match("^([^:]+):%s*(.*)$")
                        if k then headers[k:lower()] = v:gsub("%s+$", "") end
                    end
                    local req = { method = method, path = path, headers = headers }
                    local ok_u, uerr = M.upgrade(req, conn, handler, opts)
                    if not ok_u then conn:close() end
                end
            end
        end
    end
    server:close()
    return true
end

return M
