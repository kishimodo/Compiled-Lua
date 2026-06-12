-- redis -- Redis client speaking RESP3 (with RESP2 fallback) over
--          `socket` (plaintext) or `tls_client` (rediss://).
--
-- Public surface:
--   redis.connect(host?, port?, opts?)   -> conn | nil, err
--     opts:
--       password   -- AUTH on connect (or part of HELLO 3 AUTH)
--       username   -- ACL user (RESP3 HELLO 3 AUTH <u> <p>)
--       db         -- SELECT after auth (default 0)
--       client_name -- CLIENT SETNAME
--       use_tls    -- force TLS (otherwise inferred from port==6380 / scheme)
--       tls_opts   -- forwarded to tls_client.connect
--       timeout    -- ms per socket op (default 30000)
--       resp3      -- attempt HELLO 3 (default true). Falls back to RESP2
--                     if the server is < 6.0 and refuses HELLO.
--       url        -- "redis://[user[:pass]@]host[:port][/db]" or
--                     "rediss://..." for TLS. Parsed if present and
--                     individual fields take precedence over URL parts.
--
--   conn methods (general):
--     :command(name, ...)         -> reply | nil, err
--     :pipeline()                 -> pipe object
--     :multi() / :exec() / :discard()
--     :subscribe(channel, cb)     -- starts a pub/sub read loop (blocks)
--     :psubscribe(pattern, cb)
--     :publish(channel, msg)
--     :select(db) / :auth(user?, pass) / :hello(proto?)
--     :ping(msg?) / :quit() / :close()
--     :reconnect()                -> ok | nil, err
--     :is_closed()
--
--   conn methods (typed shortcuts):
--     strings:   :get :set :setex :psetex :setnx :mset :msetnx :mget
--                :append :strlen :incr :incrby :incrbyfloat :decr :decrby
--                :getrange :setrange
--     keys:      :del :unlink :exists :expire :pexpire :ttl :pttl :persist
--                :type :rename :renamenx :keys :scan :randomkey :touch
--                :dump :restore :object
--     hashes:    :hget :hset :hmget :hmset :hdel :hexists :hgetall
--                :hincrby :hincrbyfloat :hkeys :hvals :hlen :hsetnx :hscan
--     lists:     :lpush :rpush :lpop :rpop :llen :lrange :lindex :lset
--                :linsert :lrem :ltrim :rpoplpush :blpop :brpop
--     sets:      :sadd :srem :smembers :sismember :scard :spop :srandmember
--                :sunion :sinter :sdiff :sscan
--     zsets:     :zadd :zrem :zrange :zrevrange :zrangebyscore :zrank
--                :zrevrank :zincrby :zscore :zcard :zcount :zscan
--     server:    :info :dbsize :flushdb :flushall :time :config_get :config_set
--                :client_id :client_list :debug
--
-- Reply shape:
--   integers and doubles -> Lua numbers
--   simple/blob strings  -> Lua strings
--   nulls                -> redis.NULL sentinel
--   booleans (RESP3)     -> Lua booleans
--   arrays / sets        -> 1-indexed Lua arrays
--   maps  (RESP3)        -> Lua tables (string keys); plus .__order list
--   errors               -> nil, "<KIND> <message>"   (returned, never thrown)
--
-- MOVED / ASK:
--   automatically transparently redirected up to opts.max_redirects (default 5)
--   for a single command. Pipelines and pub/sub do not auto-follow.

local socket = require "socket"
local tls    = require "tls_client"

local M = {}

-- ============================================================
-- Sentinels
-- ============================================================

local NULL = setmetatable({}, { __tostring = function() return "redis.NULL" end })
M.NULL = NULL

-- ============================================================
-- URL parser
-- ============================================================

local function parse_url(url)
    -- redis[s]://[user[:pass]@]host[:port][/db]
    local scheme, rest = url:match("^(redis[s]?)://(.*)$")
    if not scheme then return nil, "not a redis url" end
    local userinfo
    local at = rest:find("@", 1, true)
    if at then
        userinfo = rest:sub(1, at - 1)
        rest = rest:sub(at + 1)
    end
    local host, port, dbpart
    local slash = rest:find("/", 1, true)
    local hp = slash and rest:sub(1, slash - 1) or rest
    if slash then dbpart = rest:sub(slash + 1) end
    if hp:sub(1, 1) == "[" then
        local rb = hp:find("]", 2, true)
        host = hp:sub(2, rb - 1)
        if hp:sub(rb + 1, rb + 1) == ":" then
            port = tonumber(hp:sub(rb + 2))
        end
    else
        local colon = hp:find(":", 1, true)
        if colon then
            host = hp:sub(1, colon - 1)
            port = tonumber(hp:sub(colon + 1))
        else
            host = hp
        end
    end
    local user, pass
    if userinfo then
        local c = userinfo:find(":", 1, true)
        if c then
            user = userinfo:sub(1, c - 1); pass = userinfo:sub(c + 1)
        else
            pass = userinfo
        end
    end
    return {
        scheme   = scheme,
        host     = host,
        port     = port or (scheme == "rediss" and 6380 or 6379),
        username = user ~= "" and user or nil,
        password = pass ~= "" and pass or nil,
        db       = tonumber(dbpart),
        use_tls  = scheme == "rediss",
    }
end

-- ============================================================
-- RESP3 encoder
--   Commands always use RESP2 multibulk wire format. The server only
--   sends RESP3 frames if we negotiated HELLO 3, but the *write* side
--   stays multibulk in both modes.
-- ============================================================

local function encode_command(args)
    -- args = list of strings/numbers (already flattened)
    local buf, n = {}, 0
    n = n + 1; buf[n] = "*" .. #args .. "\r\n"
    for i = 1, #args do
        local s = tostring(args[i])
        n = n + 1; buf[n] = "$" .. #s .. "\r\n" .. s .. "\r\n"
    end
    return table.concat(buf)
end

-- ============================================================
-- RESP3 decoder
-- ============================================================

local read_reply  -- forward

local function err_reply(line)
    -- Server-style error: "<KIND> message" -> "ERR foo bar"
    return nil, line
end

local function read_n(conn, n)
    -- Read exactly n bytes plus trailing CRLF; return n-byte payload.
    local payload, err = conn:read_exact(n)
    if not payload then return nil, err end
    local crlf, err2 = conn:read_exact(2)
    if not crlf then return nil, err2 end
    return payload
end

local function read_line_clean(conn)
    return conn:read_line({ crlf = true, max_bytes = 65536 })
end

local function decode_simple_str(s) return s end

local function decode_int(s)
    return tonumber(s)
end

local function decode_double(s)
    if s == "inf"  or s == "+inf"  then return math.huge end
    if s == "-inf" then return -math.huge end
    if s == "nan"  then return 0/0 end
    return tonumber(s)
end

local function decode_bool(s)
    return s == "t"
end

local function read_blob(conn, line)
    -- "$<len>\r\n<bytes>\r\n"  or  "$-1\r\n" (RESP2 null bulk)
    local n = tonumber(line)
    if not n or n < 0 then return NULL end
    if n == 0 then
        local crlf = conn:read_exact(2)
        if not crlf then return nil, "short blob" end
        return ""
    end
    return read_n(conn, n)
end

local function read_verbatim(conn, line)
    -- "=<len>\r\ntxt:Hello\r\n"
    local n = tonumber(line)
    if not n or n < 0 then return NULL end
    local raw, err = read_n(conn, n)
    if not raw then return nil, err end
    -- Drop the 4-char "fmt:" prefix; expose verbatim content.
    return raw:sub(5)
end

local function read_big(conn, line)
    -- RESP3 BigNumber "(": arbitrary precision integer-as-string.
    -- We keep the original string -- Lua numbers cannot hold all values.
    return line
end

local function read_array(conn, line, kind)
    local n = tonumber(line)
    if not n or n < 0 then return NULL end
    local out = {}
    for i = 1, n do
        local v, err = read_reply(conn)
        if v == nil and err then return nil, err end
        out[i] = v
    end
    if kind == "set" then
        -- Set type carries an order-flat list; mark for callers.
        getmetatable(out) -- nothing yet
    end
    return out
end

local function read_map(conn, line)
    local n = tonumber(line)
    if not n or n < 0 then return NULL end
    local out, order = {}, {}
    for i = 1, n do
        local k, kerr = read_reply(conn)
        if k == nil and kerr then return nil, kerr end
        local v, verr = read_reply(conn)
        if v == nil and verr then return nil, verr end
        local sk = type(k) == "string" and k or tostring(k)
        out[sk] = v
        order[i] = sk
    end
    out.__order = order
    return out
end

local function read_attribute(conn, line)
    -- RESP3 attribute frame -- metadata attached to the *next* reply.
    -- We read and ignore it; the next read_reply will return the actual.
    local _, err = read_map(conn, line)
    if err then return nil, err end
    return read_reply(conn)
end

local function read_push(conn, line)
    -- Out-of-band push (pub/sub etc). Same payload shape as array.
    return read_array(conn, line, "push")
end

-- Forward fill-in.
function read_reply(conn)
    local line, err = read_line_clean(conn)
    if not line then return nil, err end
    if #line == 0 then return nil, "empty reply line" end
    local tag, rest = line:sub(1, 1), line:sub(2)
    if     tag == "+" then return decode_simple_str(rest)
    elseif tag == "-" then return err_reply(rest)
    elseif tag == ":" then return decode_int(rest)
    elseif tag == "$" then return read_blob(conn, rest)
    elseif tag == "*" then return read_array(conn, rest, "array")
    elseif tag == "_" then return NULL              -- RESP3 null
    elseif tag == "#" then return decode_bool(rest) -- RESP3 boolean
    elseif tag == "," then return decode_double(rest)
    elseif tag == "(" then return read_big(conn, rest)
    elseif tag == "!" then                          -- RESP3 blob error
        local payload, perr = read_blob(conn, rest)
        if not payload then return nil, perr end
        return nil, payload
    elseif tag == "=" then return read_verbatim(conn, rest)
    elseif tag == "%" then return read_map(conn, rest)
    elseif tag == "~" then return read_array(conn, rest, "set")
    elseif tag == ">" then return read_push(conn, rest)
    elseif tag == "|" then return read_attribute(conn, rest)
    else
        return nil, "unknown RESP tag: " .. tag
    end
end

-- ============================================================
-- Connection class
-- ============================================================

local conn_mt = {}
conn_mt.__index = conn_mt

local init_handshake  -- forward declaration; defined below

local function open_transport(host, port, opts)
    if opts.use_tls then
        return tls.connect(host, port, opts.tls_opts or {})
    end
    return socket.tcp.connect(host, port, {
        timeout = opts.timeout,
        nodelay = true,
    })
end

-- Flush a single command + read a single reply (the common case).
local function send_one(self, args)
    local wire = encode_command(args)
    local ok, err = self.transport:write(wire)
    if not ok then return nil, err end
    return read_reply(self.transport)
end

-- Send many commands then read N replies (pipelining).
local function send_many(self, batches)
    local parts, n = {}, 0
    for _, args in ipairs(batches) do
        n = n + 1; parts[n] = encode_command(args)
    end
    local ok, err = self.transport:write(table.concat(parts))
    if not ok then return nil, err end
    local out = {}
    for i = 1, #batches do
        local r, rerr = read_reply(self.transport)
        if r == nil and rerr then
            out[i] = { err = rerr }
        else
            out[i] = r
        end
    end
    return out
end

-- Move-redirect (MOVED slot host:port) handling helper.
local function follow_redirect(self, args, err, depth)
    if depth >= (self._max_redirects or 5) then
        return nil, err
    end
    local kind, target = err:match("^(MOVED)%s+%d+%s+(%S+)$")
    if not kind then
        kind, target = err:match("^(ASK)%s+%d+%s+(%S+)$")
    end
    if not kind then return nil, err end
    local h, p = target:match("^(.+):(%d+)$")
    if not h then return nil, err end
    -- Open a one-shot connection to the target node. We do not mutate
    -- self -- single-command redirect only.
    local tmp, terr = M.connect(h, tonumber(p), {
        password   = self._opts.password,
        username   = self._opts.username,
        db         = self._opts.db,
        use_tls    = self._opts.use_tls,
        tls_opts   = self._opts.tls_opts,
        timeout    = self._opts.timeout,
        resp3      = self._proto3,
    })
    if not tmp then return nil, terr end
    if kind == "ASK" then
        local ok, aerr = tmp:command("ASKING")
        if not ok and aerr then tmp:close(); return nil, aerr end
    end
    local r, rerr = send_one(tmp, args)
    tmp:close()
    if rerr and (rerr:match("^MOVED") or rerr:match("^ASK")) then
        return follow_redirect(self, args, rerr, depth + 1)
    end
    return r, rerr
end

function conn_mt:command(name, ...)
    if self._closed then return nil, "closed" end
    local args = { name }
    -- Flatten any table arguments one level (mset {k,v,k,v} style).
    for i = 1, select("#", ...) do
        local a = select(i, ...)
        if type(a) == "table" then
            for _, sub in ipairs(a) do args[#args + 1] = sub end
        else
            args[#args + 1] = a
        end
    end
    local r, err = send_one(self, args)
    if err and (err:match("^MOVED") or err:match("^ASK")) then
        return follow_redirect(self, args, err, 0)
    end
    return r, err
end

function conn_mt:raw_command(args)
    -- Direct: bypass the auto-flatten so callers can ship arbitrary args.
    if self._closed then return nil, "closed" end
    return send_one(self, args)
end

function conn_mt:close()
    if self._closed then return end
    self._closed = true
    pcall(function() self.transport:close() end)
end

function conn_mt:is_closed()
    return self._closed
end

function conn_mt:set_timeout(ms)
    if self.transport.set_timeout then self.transport:set_timeout(ms) end
    self._opts.timeout = ms
end

function conn_mt:reconnect()
    self:close()
    local t, err = open_transport(self._opts.host, self._opts.port, self._opts)
    if not t then return nil, err end
    self.transport = t
    self._closed = false
    if self._opts.timeout then self.transport:set_timeout(self._opts.timeout) end
    -- Re-do AUTH/SELECT/HELLO.
    local ok, herr = init_handshake(self)
    if not ok then self:close(); return nil, herr end
    return true
end

-- ============================================================
-- Handshake
-- ============================================================

init_handshake = function(self)
    local opts = self._opts
    if opts.resp3 ~= false then
        local args = { "HELLO", "3" }
        if opts.password then
            args[#args + 1] = "AUTH"
            args[#args + 1] = opts.username or "default"
            args[#args + 1] = opts.password
        end
        if opts.client_name then
            args[#args + 1] = "SETNAME"
            args[#args + 1] = opts.client_name
        end
        local r, err = send_one(self, args)
        if r ~= nil then
            self._proto3   = true
            self._serverinfo = r
        else
            -- Older server -- fall back: clear the AUTH-via-HELLO state and
            -- do classic AUTH/SELECT.
            if err and err:match("unknown command") then
                self._proto3 = false
            elseif err and (err:match("^WRONGPASS") or err:match("^NOAUTH")
                          or err:match("^ERR Client sent AUTH")) then
                return false, err
            else
                self._proto3 = false
            end
        end
    end
    if not self._proto3 then
        if opts.password then
            local args = { "AUTH" }
            if opts.username then args[#args + 1] = opts.username end
            args[#args + 1] = opts.password
            local r, err = send_one(self, args)
            if not r and err then return false, err end
        end
        if opts.client_name then
            send_one(self, { "CLIENT", "SETNAME", opts.client_name })
        end
    end
    if opts.db and opts.db ~= 0 then
        local r, err = send_one(self, { "SELECT", tostring(opts.db) })
        if not r and err then return false, err end
    end
    return true
end

-- ============================================================
-- Top-level connect
-- ============================================================

function M.connect(host, port, opts)
    -- Argument-shape massaging: connect(url) / connect(opts) / connect(host, port, opts).
    if type(host) == "table" then
        opts = host; host = nil; port = nil
    elseif type(host) == "string" and host:match("^redis[s]?://") then
        opts = port or {}
        local u, uerr = parse_url(host)
        if not u then return nil, uerr end
        for k, v in pairs(u) do if opts[k] == nil then opts[k] = v end end
        host = opts.host; port = opts.port
    else
        opts = opts or {}
    end
    if opts.url then
        local u, uerr = parse_url(opts.url)
        if not u then return nil, uerr end
        for k, v in pairs(u) do if opts[k] == nil then opts[k] = v end end
    end
    host = host or opts.host or "127.0.0.1"
    port = port or opts.port or (opts.use_tls and 6380 or 6379)
    opts.host    = host
    opts.port    = port
    opts.timeout = opts.timeout or 30000

    local t, terr = open_transport(host, port, opts)
    if not t then return nil, terr end
    if opts.timeout and t.set_timeout then t:set_timeout(opts.timeout) end

    local conn = setmetatable({
        transport      = t,
        _closed        = false,
        _opts          = opts,
        _proto3        = false,
        _max_redirects = opts.max_redirects or 5,
        _in_pubsub     = false,
        _in_multi      = false,
    }, conn_mt)

    local ok, herr = init_handshake(conn)
    if not ok then conn:close(); return nil, herr end
    return conn
end

-- ============================================================
-- Pipeline
-- ============================================================

local pipe_mt = {}
pipe_mt.__index = pipe_mt

function pipe_mt:command(name, ...)
    local args = { name }
    for i = 1, select("#", ...) do
        local a = select(i, ...)
        if type(a) == "table" then
            for _, sub in ipairs(a) do args[#args + 1] = sub end
        else
            args[#args + 1] = a
        end
    end
    self._batches[#self._batches + 1] = args
    return self
end

function pipe_mt:execute()
    if #self._batches == 0 then return {} end
    return send_many(self._conn, self._batches)
end

pipe_mt.exec = pipe_mt.execute -- alias

function conn_mt:pipeline()
    return setmetatable({ _conn = self, _batches = {} }, pipe_mt)
end

-- ============================================================
-- Transactions
-- ============================================================

function conn_mt:multi()
    local r, err = send_one(self, { "MULTI" })
    if not r and err then return nil, err end
    self._in_multi = true
    return r
end

function conn_mt:exec()
    if not self._in_multi then return nil, "not in MULTI" end
    local r, err = send_one(self, { "EXEC" })
    self._in_multi = false
    return r, err
end

function conn_mt:discard()
    if not self._in_multi then return nil, "not in MULTI" end
    local r, err = send_one(self, { "DISCARD" })
    self._in_multi = false
    return r, err
end

function conn_mt:watch(...)
    return send_one(self, { "WATCH", ... })
end

function conn_mt:unwatch()
    return send_one(self, { "UNWATCH" })
end

-- ============================================================
-- Pub/Sub
-- ============================================================

local function pubsub_loop(self, kinds, cb)
    self._in_pubsub = true
    while not self._closed do
        local reply, err = read_reply(self.transport)
        if not reply then
            if err then self._in_pubsub = false; return nil, err end
            -- nil reply with no error -> connection closed gracefully.
            self._in_pubsub = false
            return true
        end
        if type(reply) == "table" then
            -- RESP2 layout: { "message", channel, payload }
            -- RESP3 push:   table from > tag, same field order.
            local kind = reply[1]
            if kinds[kind] then
                local stop = cb(reply, self)
                if stop == false then
                    self._in_pubsub = false
                    return true
                end
            end
        end
    end
    self._in_pubsub = false
    return true
end

function conn_mt:subscribe(channel, cb)
    if type(channel) == "table" then
        local args = { "SUBSCRIBE" }
        for _, c in ipairs(channel) do args[#args + 1] = c end
        local ok, err = self.transport:write(encode_command(args))
        if not ok then return nil, err end
    else
        local ok, err = self.transport:write(encode_command({ "SUBSCRIBE", channel }))
        if not ok then return nil, err end
    end
    if not cb then return true end
    return pubsub_loop(self, {
        message = true, subscribe = true, unsubscribe = true,
    }, cb)
end

function conn_mt:psubscribe(pattern, cb)
    if type(pattern) == "table" then
        local args = { "PSUBSCRIBE" }
        for _, c in ipairs(pattern) do args[#args + 1] = c end
        local ok, err = self.transport:write(encode_command(args))
        if not ok then return nil, err end
    else
        local ok, err = self.transport:write(encode_command({ "PSUBSCRIBE", pattern }))
        if not ok then return nil, err end
    end
    if not cb then return true end
    return pubsub_loop(self, {
        pmessage = true, psubscribe = true, punsubscribe = true,
    }, cb)
end

function conn_mt:unsubscribe(channel)
    local args = { "UNSUBSCRIBE" }
    if channel then args[#args + 1] = channel end
    return self.transport:write(encode_command(args))
end

function conn_mt:publish(channel, msg)
    return send_one(self, { "PUBLISH", channel, msg })
end

-- ============================================================
-- Typed shortcuts
-- Each is a thin wrapper around :command() that exists purely so
-- callers get IDE-style autocompletion and clearer call sites.
-- ============================================================

local function make_method(cmd, ...)
    local fixed = { cmd, ... }
    return function(self, ...)
        local args = { fixed[1] }
        for i = 2, #fixed do args[#args + 1] = fixed[i] end
        for i = 1, select("#", ...) do
            local a = select(i, ...)
            if type(a) == "table" then
                for _, sub in ipairs(a) do args[#args + 1] = sub end
            else
                args[#args + 1] = a
            end
        end
        return send_one(self, args)
    end
end

-- Connection / server.
conn_mt.ping       = function(self, msg) if msg then return send_one(self, { "PING", msg }) else return send_one(self, { "PING" }) end end
conn_mt.echo       = make_method("ECHO")
conn_mt.quit       = function(self) local r, e = send_one(self, { "QUIT" }); self:close(); return r, e end
conn_mt.auth       = function(self, user, pass) if pass then return send_one(self, { "AUTH", user, pass }) else return send_one(self, { "AUTH", user }) end end
conn_mt.hello      = function(self, proto) return send_one(self, { "HELLO", tostring(proto or 3) }) end
conn_mt.select     = make_method("SELECT")
conn_mt.info       = function(self, section) if section then return send_one(self, { "INFO", section }) else return send_one(self, { "INFO" }) end end
conn_mt.dbsize     = make_method("DBSIZE")
conn_mt.flushdb    = make_method("FLUSHDB")
conn_mt.flushall   = make_method("FLUSHALL")
conn_mt.time       = make_method("TIME")
conn_mt.client_id  = function(self) return send_one(self, { "CLIENT", "ID" }) end
conn_mt.client_list= function(self) return send_one(self, { "CLIENT", "LIST" }) end
conn_mt.config_get = function(self, k) return send_one(self, { "CONFIG", "GET", k }) end
conn_mt.config_set = function(self, k, v) return send_one(self, { "CONFIG", "SET", k, v }) end
conn_mt.debug      = make_method("DEBUG")

-- Strings.
conn_mt.get          = make_method("GET")
conn_mt.set          = function(self, k, v, ...)
    local args = { "SET", k, v }
    for i = 1, select("#", ...) do args[#args + 1] = select(i, ...) end
    return send_one(self, args)
end
conn_mt.setex        = make_method("SETEX")
conn_mt.psetex       = make_method("PSETEX")
conn_mt.setnx        = make_method("SETNX")
conn_mt.mset         = make_method("MSET")
conn_mt.msetnx       = make_method("MSETNX")
conn_mt.mget         = make_method("MGET")
conn_mt.append       = make_method("APPEND")
conn_mt.strlen       = make_method("STRLEN")
conn_mt.incr         = make_method("INCR")
conn_mt.incrby       = make_method("INCRBY")
conn_mt.incrbyfloat  = make_method("INCRBYFLOAT")
conn_mt.decr         = make_method("DECR")
conn_mt.decrby       = make_method("DECRBY")
conn_mt.getrange     = make_method("GETRANGE")
conn_mt.setrange     = make_method("SETRANGE")
conn_mt.getset       = make_method("GETSET")

-- Keys.
conn_mt.del      = make_method("DEL")
conn_mt.unlink   = make_method("UNLINK")
conn_mt.exists   = make_method("EXISTS")
conn_mt.expire   = make_method("EXPIRE")
conn_mt.pexpire  = make_method("PEXPIRE")
conn_mt.expireat = make_method("EXPIREAT")
conn_mt.ttl      = make_method("TTL")
conn_mt.pttl     = make_method("PTTL")
conn_mt.persist  = make_method("PERSIST")
conn_mt.type     = make_method("TYPE")
conn_mt.rename   = make_method("RENAME")
conn_mt.renamenx = make_method("RENAMENX")
conn_mt.keys     = make_method("KEYS")
conn_mt.scan     = make_method("SCAN")
conn_mt.randomkey= make_method("RANDOMKEY")
conn_mt.touch    = make_method("TOUCH")
conn_mt.dump     = make_method("DUMP")
conn_mt.restore  = make_method("RESTORE")
conn_mt.object   = make_method("OBJECT")
conn_mt.copy     = make_method("COPY")

-- Hashes.
conn_mt.hget         = make_method("HGET")
conn_mt.hset         = make_method("HSET")
conn_mt.hmget        = make_method("HMGET")
conn_mt.hmset        = make_method("HMSET")
conn_mt.hdel         = make_method("HDEL")
conn_mt.hexists      = make_method("HEXISTS")
conn_mt.hgetall      = make_method("HGETALL")
conn_mt.hincrby      = make_method("HINCRBY")
conn_mt.hincrbyfloat = make_method("HINCRBYFLOAT")
conn_mt.hkeys        = make_method("HKEYS")
conn_mt.hvals        = make_method("HVALS")
conn_mt.hlen         = make_method("HLEN")
conn_mt.hsetnx       = make_method("HSETNX")
conn_mt.hscan        = make_method("HSCAN")
conn_mt.hstrlen      = make_method("HSTRLEN")

-- Lists.
conn_mt.lpush     = make_method("LPUSH")
conn_mt.rpush     = make_method("RPUSH")
conn_mt.lpushx    = make_method("LPUSHX")
conn_mt.rpushx    = make_method("RPUSHX")
conn_mt.lpop      = make_method("LPOP")
conn_mt.rpop      = make_method("RPOP")
conn_mt.llen      = make_method("LLEN")
conn_mt.lrange    = make_method("LRANGE")
conn_mt.lindex    = make_method("LINDEX")
conn_mt.lset      = make_method("LSET")
conn_mt.linsert   = make_method("LINSERT")
conn_mt.lrem      = make_method("LREM")
conn_mt.ltrim     = make_method("LTRIM")
conn_mt.rpoplpush = make_method("RPOPLPUSH")
conn_mt.blpop     = make_method("BLPOP")
conn_mt.brpop     = make_method("BRPOP")
conn_mt.lmove     = make_method("LMOVE")
conn_mt.blmove    = make_method("BLMOVE")

-- Sets.
conn_mt.sadd        = make_method("SADD")
conn_mt.srem        = make_method("SREM")
conn_mt.smembers    = make_method("SMEMBERS")
conn_mt.sismember   = make_method("SISMEMBER")
conn_mt.smismember  = make_method("SMISMEMBER")
conn_mt.scard       = make_method("SCARD")
conn_mt.spop        = make_method("SPOP")
conn_mt.srandmember = make_method("SRANDMEMBER")
conn_mt.sunion      = make_method("SUNION")
conn_mt.sinter      = make_method("SINTER")
conn_mt.sdiff       = make_method("SDIFF")
conn_mt.sunionstore = make_method("SUNIONSTORE")
conn_mt.sinterstore = make_method("SINTERSTORE")
conn_mt.sdiffstore  = make_method("SDIFFSTORE")
conn_mt.sscan       = make_method("SSCAN")
conn_mt.smove       = make_method("SMOVE")

-- Sorted sets.
conn_mt.zadd           = make_method("ZADD")
conn_mt.zrem           = make_method("ZREM")
conn_mt.zrange         = make_method("ZRANGE")
conn_mt.zrevrange      = make_method("ZREVRANGE")
conn_mt.zrangebyscore  = make_method("ZRANGEBYSCORE")
conn_mt.zrevrangebyscore = make_method("ZREVRANGEBYSCORE")
conn_mt.zrangebylex    = make_method("ZRANGEBYLEX")
conn_mt.zrank          = make_method("ZRANK")
conn_mt.zrevrank       = make_method("ZREVRANK")
conn_mt.zincrby        = make_method("ZINCRBY")
conn_mt.zscore         = make_method("ZSCORE")
conn_mt.zcard          = make_method("ZCARD")
conn_mt.zcount         = make_method("ZCOUNT")
conn_mt.zscan          = make_method("ZSCAN")
conn_mt.zpopmin        = make_method("ZPOPMIN")
conn_mt.zpopmax        = make_method("ZPOPMAX")
conn_mt.bzpopmin       = make_method("BZPOPMIN")
conn_mt.bzpopmax       = make_method("BZPOPMAX")
conn_mt.zremrangebyrank  = make_method("ZREMRANGEBYRANK")
conn_mt.zremrangebyscore = make_method("ZREMRANGEBYSCORE")

-- Streams (a subset; full XADD options pass through as varargs).
conn_mt.xadd   = make_method("XADD")
conn_mt.xread  = make_method("XREAD")
conn_mt.xrange = make_method("XRANGE")
conn_mt.xlen   = make_method("XLEN")
conn_mt.xdel   = make_method("XDEL")

-- Scripting.
conn_mt.eval     = make_method("EVAL")
conn_mt.evalsha  = make_method("EVALSHA")
conn_mt.script   = make_method("SCRIPT")

-- ============================================================
-- Convenience: open(url) shorthand
-- ============================================================

function M.open(url, opts)
    return M.connect(url, nil, opts)
end

return M
