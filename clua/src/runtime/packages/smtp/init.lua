-- smtp -- SMTP submission client.
--
-- Public surface:
--   smtp.send(opts) -> ok | nil, err
--     opts:
--       server       = "smtp.example.com"
--       port         = 587  (default; 465 for implicit TLS, 25 plain)
--       use_tls      = true  -- STARTTLS upgrade on port 587; implicit TLS on 465
--       starttls     = true  -- explicit STARTTLS even if use_tls=false
--       user         = "..."  -- triggers AUTH PLAIN / LOGIN
--       password     = "..."
--       auth         = "plain" | "login"  (default plain)
--       from         = "alice@example.com" or { addr = ..., name = ... }
--       to           = "bob@example.com" or { ... }    (string or list)
--       cc           = ...
--       bcc          = ...                              (envelope only, not in headers)
--       subject      = "Subject string"
--       text         = "Plain text body"
--       html         = "<p>HTML body</p>"
--       attachments  = { { filename=, content=, mime= } }
--       headers      = { ["X-Custom"] = "value" }      -- extra headers
--       tls_opts     = { verify=..., server_name=... }
--       timeout      = ms (default 30000)
--       hostname     = HELO/EHLO identity (default "clua-interp.local")
--
--   smtp.build_message(opts) -> string  -- the RFC 5322 message body
--     useful for callers who want to ship the message via a different
--     transport.

local ffi    = ffi
require "windows"
local socket = require "socket"
local tls    = require "tls_client"

local M = {}

-- ============================================================
-- Helpers: address & header formatting
-- ============================================================

local function fmt_addr(a)
    if type(a) == "table" then
        if a.name then return string.format('"%s" <%s>', a.name, a.addr) end
        return a.addr
    end
    return tostring(a)
end

local function addr_of(a)
    if type(a) == "table" then return a.addr end
    -- Extract <addr> if present.
    local inside = (a or ""):match("<([^>]+)>")
    return inside or a
end

local function as_list(v)
    if v == nil then return {} end
    if type(v) == "table" and not v.addr and not v.name then
        return v
    end
    return { v }
end

local function header_join(name, items)
    if #items == 0 then return nil end
    local parts = {}
    for i, a in ipairs(items) do parts[i] = fmt_addr(a) end
    return name .. ": " .. table.concat(parts, ", ")
end

-- ============================================================
-- base64 (encode-only -- we already have one in websocket but inlining
-- here keeps smtp standalone)
-- ============================================================

local _b64a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(s)
    local out, n = {}, 0
    local len = #s
    local i = 1
    while i + 2 <= len do
        local a, b, c = s:byte(i), s:byte(i + 1), s:byte(i + 2)
        local v = (a << 16) | (b << 8) | c
        n = n + 1; out[n] = _b64a:sub((v >> 18) + 1, (v >> 18) + 1)
                          .. _b64a:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
                          .. _b64a:sub(((v >>  6) & 63) + 1, ((v >>  6) & 63) + 1)
                          .. _b64a:sub(((v      ) & 63) + 1, ((v      ) & 63) + 1)
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local a = s:byte(i)
        local v = a << 16
        n = n + 1; out[n] = _b64a:sub((v >> 18) + 1, (v >> 18) + 1)
                          .. _b64a:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
                          .. "=="
    elseif rem == 2 then
        local a, b = s:byte(i), s:byte(i + 1)
        local v = (a << 16) | (b << 8)
        n = n + 1; out[n] = _b64a:sub((v >> 18) + 1, (v >> 18) + 1)
                          .. _b64a:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
                          .. _b64a:sub(((v >>  6) & 63) + 1, ((v >>  6) & 63) + 1)
                          .. "="
    end
    return table.concat(out)
end

-- Encode a blob into base64 with CRLF every 76 chars (RFC 2045).
local function b64_wrap_76(s)
    local raw = b64encode(s)
    if #raw <= 76 then return raw end
    local parts, n = {}, 0
    for i = 1, #raw, 76 do
        n = n + 1; parts[n] = raw:sub(i, i + 75)
    end
    return table.concat(parts, "\r\n")
end

-- ============================================================
-- MIME / RFC 5322 message construction
-- ============================================================

-- Random-ish boundary string. Uses time + counter; doesn't need to be
-- crypto-strong, just statistically unique within the body.
local _boundary_seq = 0
local function gen_boundary()
    _boundary_seq = _boundary_seq + 1
    return string.format("----=CLuaSMTP_%d_%d", os.time(), _boundary_seq)
end

-- Generate an RFC 5322 Date header from os.time().
local function rfc5322_date()
    return os.date("!%a, %d %b %Y %H:%M:%S +0000")
end

-- Build a Message-Id using hostname + time + counter.
local function gen_message_id(hostname)
    return string.format("<%d.%d@%s>", os.time(), _boundary_seq, hostname or "localhost")
end

-- Build the message body. Body shape depends on which fields are set:
--   text only   -> text/plain
--   html only   -> text/html
--   text+html   -> multipart/alternative
--   plus attachments -> multipart/mixed wrapping the above
local function build_body(opts)
    local has_text  = opts.text and #opts.text > 0
    local has_html  = opts.html and #opts.html > 0
    local has_att   = opts.attachments and #opts.attachments > 0

    local function plain_part(kind, content)
        return string.format(
            "Content-Type: %s; charset=utf-8\r\n"
            .. "Content-Transfer-Encoding: 8bit\r\n\r\n%s",
            kind, content)
    end

    local function attachment_part(att)
        local fn = att.filename or "attachment.bin"
        local mt = att.mime or "application/octet-stream"
        return string.format(
            "Content-Type: %s; name=\"%s\"\r\n"
            .. "Content-Transfer-Encoding: base64\r\n"
            .. "Content-Disposition: attachment; filename=\"%s\"\r\n\r\n%s",
            mt, fn, fn, b64_wrap_76(att.content))
    end

    -- Single-part shortcuts.
    if not has_att and has_text and not has_html then
        return "Content-Type: text/plain; charset=utf-8\r\n"
            .. "Content-Transfer-Encoding: 8bit\r\n", opts.text
    end
    if not has_att and not has_text and has_html then
        return "Content-Type: text/html; charset=utf-8\r\n"
            .. "Content-Transfer-Encoding: 8bit\r\n", opts.html
    end

    local alt_body
    local alt_headers
    if has_text and has_html then
        local b = gen_boundary()
        alt_headers = string.format(
            "Content-Type: multipart/alternative; boundary=\"%s\"\r\n", b)
        local parts = {
            "--" .. b,
            plain_part("text/plain", opts.text or ""),
            "--" .. b,
            plain_part("text/html",  opts.html or ""),
            "--" .. b .. "--",
        }
        alt_body = table.concat(parts, "\r\n")
    elseif has_text then
        alt_headers = "Content-Type: text/plain; charset=utf-8\r\n"
                   .. "Content-Transfer-Encoding: 8bit\r\n"
        alt_body = opts.text
    elseif has_html then
        alt_headers = "Content-Type: text/html; charset=utf-8\r\n"
                   .. "Content-Transfer-Encoding: 8bit\r\n"
        alt_body = opts.html
    else
        alt_headers = "Content-Type: text/plain; charset=utf-8\r\n"
                   .. "Content-Transfer-Encoding: 8bit\r\n"
        alt_body = ""
    end

    if not has_att then
        return alt_headers, alt_body
    end

    -- Wrap in multipart/mixed.
    local b = gen_boundary()
    local hdr = string.format(
        "Content-Type: multipart/mixed; boundary=\"%s\"\r\n", b)
    local parts = { "--" .. b, alt_headers .. "\r\n" .. alt_body }
    for _, a in ipairs(opts.attachments) do
        parts[#parts + 1] = "--" .. b
        parts[#parts + 1] = attachment_part(a)
    end
    parts[#parts + 1] = "--" .. b .. "--"
    return hdr, table.concat(parts, "\r\n")
end

function M.build_message(opts)
    local body_hdr, body = build_body(opts)
    local lines = {}
    local to_list = as_list(opts.to)
    local cc_list = as_list(opts.cc)
    lines[#lines + 1] = "From: " .. fmt_addr(opts.from)
    local th = header_join("To", to_list)
    if th then lines[#lines + 1] = th end
    local ch = header_join("Cc", cc_list)
    if ch then lines[#lines + 1] = ch end
    lines[#lines + 1] = "Subject: " .. (opts.subject or "")
    lines[#lines + 1] = "Date: " .. rfc5322_date()
    lines[#lines + 1] = "Message-Id: " .. gen_message_id(opts.hostname)
    lines[#lines + 1] = "MIME-Version: 1.0"
    if opts.headers then
        for k, v in pairs(opts.headers) do
            lines[#lines + 1] = k .. ": " .. v
        end
    end
    -- body_hdr already has trailing CRLF; append directly.
    lines[#lines + 1] = body_hdr:gsub("\r\n$", "")
    lines[#lines + 1] = ""    -- blank line separating headers from body
    lines[#lines + 1] = body
    return table.concat(lines, "\r\n")
end

-- ============================================================
-- SMTP conversation
-- ============================================================

-- Read a multi-line SMTP response. Each line is "NNN-..." for
-- continuation; the final line is "NNN ..." (space after code).
local function read_reply(conn)
    local lines = {}
    while true do
        local line, err = conn:read_line({ crlf = true, max_bytes = 4096 })
        if not line then return nil, err end
        lines[#lines + 1] = line
        if #line < 4 then return nil, "bad smtp line: " .. line end
        local sep = line:sub(4, 4)
        if sep == " " or sep == "" then
            return tonumber(line:sub(1, 3)), table.concat(lines, "\n")
        end
    end
end

local function expect(conn, want)
    local code, text = read_reply(conn)
    if not code then return nil, text end
    if code ~= want then
        return nil, string.format("smtp expected %d got %d: %s", want, code, text)
    end
    return code, text
end

local function send_line(conn, line)
    local ok, err = conn:write(line .. "\r\n")
    if not ok then return nil, err end
    return true
end

-- "Dot-stuffing": any line beginning with "." must be doubled in the
-- DATA payload so it isn't mistaken for the end-of-data marker. The
-- final ".\r\n" must NOT be dot-stuffed.
local function dot_stuff(body)
    -- Lua's gsub line-by-line approach: split on CRLF, prefix lines.
    -- Cheaper to operate on the whole string via pattern replace.
    -- A leading dot can appear only at line start: ^ or after \r\n.
    body = body:gsub("\r\n%.", "\r\n..")
    if body:sub(1, 1) == "." then body = "." .. body end
    return body
end

-- ============================================================
-- AUTH
-- ============================================================

local function auth_plain(conn, user, password)
    -- "AUTH PLAIN <base64(\0user\0pass)>"
    local payload = b64encode("\0" .. user .. "\0" .. password)
    local ok, err = send_line(conn, "AUTH PLAIN " .. payload)
    if not ok then return nil, err end
    return expect(conn, 235)
end

local function auth_login(conn, user, password)
    local ok, err = send_line(conn, "AUTH LOGIN")
    if not ok then return nil, err end
    local code; code, err = read_reply(conn)
    if code ~= 334 then return nil, "AUTH LOGIN refused: " .. tostring(err) end
    ok, err = send_line(conn, b64encode(user))
    if not ok then return nil, err end
    code, err = read_reply(conn)
    if code ~= 334 then return nil, "AUTH LOGIN user refused: " .. tostring(err) end
    ok, err = send_line(conn, b64encode(password))
    if not ok then return nil, err end
    return expect(conn, 235)
end

-- ============================================================
-- EHLO / capability parsing
-- ============================================================

local function ehlo(conn, hostname)
    local ok, err = send_line(conn, "EHLO " .. (hostname or "clua-interp.local"))
    if not ok then return nil, err end
    local code, text = read_reply(conn)
    if code ~= 250 then return nil, "EHLO failed: " .. tostring(text) end
    local caps = {}
    for line in text:gmatch("[^\n]+") do
        local body = line:sub(5)   -- strip "NNN-" or "NNN "
        local kw = body:match("^(%S+)")
        if kw then caps[kw:upper()] = body end
    end
    return caps
end

-- ============================================================
-- Public entry
-- ============================================================

function M.send(opts)
    if not opts.from   then return nil, "smtp.send: missing from"   end
    if not opts.to     then return nil, "smtp.send: missing to"     end
    if not opts.server then return nil, "smtp.send: missing server" end

    local port = opts.port or 587
    local timeout = opts.timeout or 30000
    local conn, err

    -- Implicit-TLS on port 465; otherwise plaintext + optional STARTTLS.
    local implicit_tls = (port == 465) or (opts.use_tls and port == 465)
    if implicit_tls then
        conn, err = tls.connect(opts.server, port,
            opts.tls_opts or { timeout = timeout })
    else
        conn, err = socket.tcp.connect(opts.server, port,
            { timeout = timeout, nodelay = true })
    end
    if not conn then return nil, err end

    -- Greeting
    local code, text = read_reply(conn)
    if code ~= 220 then conn:close(); return nil, "no smtp greeting: " .. tostring(text) end

    -- EHLO
    local caps; caps, err = ehlo(conn, opts.hostname)
    if not caps then conn:close(); return nil, err end

    -- STARTTLS upgrade if requested (or explicit) and supported.
    local want_starttls = (opts.starttls == true)
                       or (opts.use_tls and not implicit_tls)
    if want_starttls then
        if not caps["STARTTLS"] then
            conn:close()
            return nil, "STARTTLS not advertised by server"
        end
        local ok; ok, err = send_line(conn, "STARTTLS")
        if not ok then conn:close(); return nil, err end
        code, text = read_reply(conn)
        if code ~= 220 then conn:close(); return nil, "STARTTLS refused: " .. tostring(text) end
        conn:close()  -- the plaintext socket needs to be replaced
        -- Reconnect over TLS to the SAME host:port. This is the simplest
        -- path: SChannel's InitializeSecurityContext doesn't easily take
        -- an existing socket; we open a fresh connection. The downside
        -- is we re-pay the TCP handshake; the upside is we don't expose
        -- tls_client's internals.
        conn, err = tls.connect(opts.server, port, opts.tls_opts
            or { timeout = timeout })
        if not conn then return nil, err end
        -- After STARTTLS handshake we must re-EHLO (per RFC 3207).
        -- But we just reopened, so a 220 greeting first.
        code, text = read_reply(conn)
        if code ~= 220 then conn:close(); return nil, "post-TLS greeting failed" end
        caps, err = ehlo(conn, opts.hostname)
        if not caps then conn:close(); return nil, err end
    end

    -- AUTH
    if opts.user and opts.password then
        local auth = (opts.auth or "plain"):lower()
        local ok; ok, err = (auth == "login")
            and auth_login(conn, opts.user, opts.password)
            or  auth_plain(conn, opts.user, opts.password)
        if not ok then conn:close(); return nil, err end
    end

    -- MAIL FROM:<addr>
    local mok; mok, err = send_line(conn,
        "MAIL FROM:<" .. addr_of(opts.from) .. ">")
    if not mok then conn:close(); return nil, err end
    local _; _, err = expect(conn, 250)
    if err then conn:close(); return nil, err end

    -- RCPT TO for every envelope recipient (to + cc + bcc).
    local rcpts = {}
    for _, r in ipairs(as_list(opts.to))  do rcpts[#rcpts + 1] = addr_of(r) end
    for _, r in ipairs(as_list(opts.cc))  do rcpts[#rcpts + 1] = addr_of(r) end
    for _, r in ipairs(as_list(opts.bcc)) do rcpts[#rcpts + 1] = addr_of(r) end
    for _, addr in ipairs(rcpts) do
        local ok2; ok2, err = send_line(conn, "RCPT TO:<" .. addr .. ">")
        if not ok2 then conn:close(); return nil, err end
        local rc, rtext = read_reply(conn)
        -- 250 ok, 251 user not local but will forward
        if rc ~= 250 and rc ~= 251 then
            conn:close()
            return nil, string.format("RCPT TO %s failed: %s", addr, tostring(rtext))
        end
    end

    -- DATA
    local ok3; ok3, err = send_line(conn, "DATA")
    if not ok3 then conn:close(); return nil, err end
    local dc, dtext = read_reply(conn)
    if dc ~= 354 then conn:close(); return nil, "DATA refused: " .. tostring(dtext) end

    local msg = M.build_message(opts)
    local payload = dot_stuff(msg) .. "\r\n.\r\n"
    local wok; wok, err = conn:write(payload)
    if not wok then conn:close(); return nil, err end
    local fc, ftext = read_reply(conn)
    if fc ~= 250 then conn:close(); return nil, "DATA finalization: " .. tostring(ftext) end

    -- QUIT (best-effort; some servers don't reply quickly).
    pcall(function() send_line(conn, "QUIT"); read_reply(conn) end)
    conn:close()
    return true
end

return M
