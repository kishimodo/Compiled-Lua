-- log -- structured logging with sinks, formatters, sampling.
--
-- Public surface:
--   log.new(opts?)                          -> logger
--   logger:trace/debug/info/warn/error/fatal(msg, fields?)
--   logger:with(fields)                     -> child logger inheriting context
--   logger:add_sink(sink)                   -> mutate in place
--   logger:set_level(level)                 -> "trace".."fatal"
--   log.<level>(msg, fields?)               -> global logger shortcut
--
-- Formatters (functions: record -> string, never trailing newline):
--   log.formatter.json(rec)
--   log.formatter.logfmt(rec)
--   log.formatter.text(rec)                 -- pretty, colorized when tty
--   log.formatter.syslog(rec, facility?)    -- RFC 5424
--
-- Sinks (tables with :write(line) and optionally :close()):
--   log.sink.stdout(opts?)                  -- {formatter=...}
--   log.sink.stderr(opts?)
--   log.sink.file(path, opts?)              -- {rotate_bytes=, rotate_age_s=, keep=}
--   log.sink.syslog(host, port?, opts?)     -- UDP RFC 5424
--   log.sink.http(url, opts?)               -- POST batches, {batch=, flush_ms=, headers=}
--
-- Sampling helpers (callable: rec -> bool keep):
--   log.sample.percent(p)                   -- 0..1 fraction
--   log.sample.ratelimit(per_sec)           -- token bucket
--
-- A record is a table:
--   { ts=epoch_seconds, level="info", msg="...", fields={...},
--     source={file=, line=, func=}, logger=name }

local M = {}

-- Soft-require pulls in optional packages without exploding when absent.
local function soft_require(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    return nil
end

local json   = soft_require("json")
local color  = soft_require("color")
local socket = soft_require("socket")

-- ===== Levels ===========================================================

local LEVELS = { trace = 10, debug = 20, info = 30, warn = 40, error = 50, fatal = 60 }
local LEVEL_NAMES = {}
for k, v in pairs(LEVELS) do LEVEL_NAMES[v] = k end
M.LEVELS = LEVELS

local function level_num(l)
    if type(l) == "number" then return l end
    return LEVELS[l] or LEVELS.info
end

-- ===== Time helpers =====================================================

local function now_seconds()
    -- Sub-second precision when available; falls back to os.time().
    if os.clock then
        -- os.time gives integer epoch; combine with a monotonic-ish fractional
        -- via os.clock to fake millisecond resolution.
        local t = os.time()
        local frac = os.clock() % 1
        return t + frac
    end
    return os.time()
end

local function format_ts_rfc3339(t)
    -- 2006-01-02T15:04:05.000Z (UTC). Local-vs-UTC choice is intentional:
    -- machine-readable logs should be UTC so multi-host timelines align.
    local sec = math.floor(t)
    local ms  = math.floor((t - sec) * 1000)
    local d = os.date("!*t", sec)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
        d.year, d.month, d.day, d.hour, d.min, d.sec, ms)
end

-- ===== Field serialization for non-JSON formatters ======================

local function tostring_value(v)
    local t = type(v)
    if t == "string" then return v end
    if t == "number" or t == "boolean" then return tostring(v) end
    if v == nil then return "nil" end
    if t == "table" then
        if json then
            local ok, s = pcall(json.encode, v)
            if ok then return s end
        end
        return tostring(v)
    end
    return tostring(v)
end

-- logfmt key=value escaping. Quote if the value contains whitespace, "= or ".
local function logfmt_escape(v)
    local s = tostring_value(v)
    if s:find("[%s\"=]") then
        s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
        return '"' .. s .. '"'
    end
    return s
end

-- ===== Formatters =======================================================

M.formatter = {}

function M.formatter.json(rec)
    -- Flatten source/logger into top-level for ergonomic Splunk/Loki queries.
    local out = {
        ts    = format_ts_rfc3339(rec.ts),
        level = rec.level,
        msg   = rec.msg,
    }
    if rec.logger then out.logger = rec.logger end
    if rec.source then
        out.source = rec.source.file .. ":" .. tostring(rec.source.line)
        if rec.source.func then out.func = rec.source.func end
    end
    if rec.fields then
        for k, v in pairs(rec.fields) do
            -- Don't let a field stomp a reserved key.
            if out[k] == nil then out[k] = v end
        end
    end
    if json then return json.encode(out) end
    -- Minimal fallback when json package isn't present.
    local parts = {}
    for k, v in pairs(out) do parts[#parts + 1] = tostring(k) .. "=" .. tostring_value(v) end
    return "{" .. table.concat(parts, ",") .. "}"
end

function M.formatter.logfmt(rec)
    local parts = {
        "ts="    .. format_ts_rfc3339(rec.ts),
        "level=" .. rec.level,
        "msg="   .. logfmt_escape(rec.msg),
    }
    if rec.logger then parts[#parts + 1] = "logger=" .. logfmt_escape(rec.logger) end
    if rec.source then
        parts[#parts + 1] = "src=" .. logfmt_escape(rec.source.file .. ":" .. tostring(rec.source.line))
    end
    if rec.fields then
        -- Sort for stable output -- helps grep diffs and tests.
        local keys = {}
        for k in pairs(rec.fields) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = k .. "=" .. logfmt_escape(rec.fields[k])
        end
    end
    return table.concat(parts, " ")
end

local LEVEL_COLORS = {
    trace = "magenta", debug = "cyan", info = "green",
    warn  = "yellow",  error = "red",  fatal = "red",
}

local function paint(s, hue, opts)
    if not opts.colorize or not color then return s end
    local fn = color[hue]
    if not fn then return s end
    return fn(s)
end

function M.formatter.text(rec, opts)
    opts = opts or {}
    opts.colorize = opts.colorize ~= false and color and color.supports_color and color.supports_color()
    local ts = os.date("%H:%M:%S", math.floor(rec.ts))
    local lvl = rec.level:upper()
    local hue = LEVEL_COLORS[rec.level] or "white"
    local lvl_str = paint(string.format("%-5s", lvl), hue, opts)
    -- bold the message body so eyes track it across noisy field clouds
    local msg = opts.colorize and color.bold and color.bold(rec.msg) or rec.msg
    local body = string.format("%s %s  %s", ts, lvl_str, msg)
    if rec.fields then
        local keys = {}
        for k in pairs(rec.fields) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local kv = " " .. k .. "=" .. logfmt_escape(rec.fields[k])
            body = body .. (opts.colorize and color.dim and color.dim(kv) or kv)
        end
    end
    if rec.source then
        local s = string.format(" (%s:%d)", rec.source.file, rec.source.line)
        body = body .. (opts.colorize and color.dim and color.dim(s) or s)
    end
    return body
end

-- RFC 5424 priority: facility*8 + severity. We map our 6 levels to syslog's 8.
local SYSLOG_SEV = { trace = 7, debug = 7, info = 6, warn = 4, error = 3, fatal = 2 }
local DEFAULT_FACILITY = 1  -- user-level messages

function M.formatter.syslog(rec, facility)
    facility = facility or DEFAULT_FACILITY
    local sev = SYSLOG_SEV[rec.level] or 6
    local pri = facility * 8 + sev
    local hostname = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "-"
    local app = rec.logger or "lua"
    -- STRUCTURED-DATA section if fields exist. We bucket them under [fields@0].
    local sd = "-"
    if rec.fields and next(rec.fields) then
        local parts = { "[fields@0" }
        for k, v in pairs(rec.fields) do
            local s = tostring_value(v):gsub('"', '\\"'):gsub("%]", "\\]"):gsub("\\", "\\\\")
            parts[#parts + 1] = string.format('%s="%s"', tostring(k), s)
        end
        parts[#parts + 1] = "]"
        sd = table.concat(parts, " ")
    end
    return string.format("<%d>1 %s %s %s - - %s %s",
        pri, format_ts_rfc3339(rec.ts), hostname, app, sd, rec.msg)
end

-- ===== Sinks ============================================================

M.sink = {}

local function default_formatter(opts)
    return (opts and opts.formatter) or M.formatter.json
end

local function stdio_sink(stream)
    return function(opts)
        opts = opts or {}
        local fmt = default_formatter(opts)
        return {
            write = function(self, rec)
                stream:write(fmt(rec, opts), "\n")
                if opts.flush then stream:flush() end
            end,
            close = function(self) end,
        }
    end
end

M.sink.stdout = stdio_sink(io.stdout)
M.sink.stderr = stdio_sink(io.stderr)

-- File sink with size/age rotation. keep=N means we shift .1..N suffix files
-- on rotate. Age-based rotation is checked lazily on every write.
function M.sink.file(path, opts)
    opts = opts or {}
    local fmt = default_formatter(opts)
    local rotate_bytes = opts.rotate_bytes
    local rotate_age_s = opts.rotate_age_s
    local keep         = opts.keep or 5

    local sink = { path = path, _bytes = 0 }
    sink._fh = assert(io.open(path, "a+"))
    -- Seek to end to learn current size for size-based rotation.
    sink._fh:seek("end")
    sink._bytes = sink._fh:seek()
    sink._opened_at = now_seconds()

    local function rotate(self)
        self._fh:close()
        -- Cascade .N -> .N+1 (drop the oldest)
        for i = keep - 1, 1, -1 do
            local from = path .. "." .. i
            local to   = path .. "." .. (i + 1)
            os.remove(to)
            os.rename(from, to)
        end
        os.rename(path, path .. ".1")
        self._fh = assert(io.open(path, "a+"))
        self._bytes = 0
        self._opened_at = now_seconds()
    end

    function sink:write(rec)
        local line = fmt(rec, opts) .. "\n"
        local need_rot = false
        if rotate_bytes and self._bytes + #line > rotate_bytes then need_rot = true end
        if rotate_age_s and now_seconds() - self._opened_at > rotate_age_s then need_rot = true end
        if need_rot then rotate(self) end
        self._fh:write(line)
        self._fh:flush()
        self._bytes = self._bytes + #line
    end

    function sink:close()
        if self._fh then self._fh:close(); self._fh = nil end
    end

    return sink
end

-- UDP syslog sink. Datagram per record. Best-effort -- a send failure is
-- swallowed silently so logging never crashes the host program.
function M.sink.syslog(host, port, opts)
    opts = opts or {}
    if not socket then error("log.sink.syslog requires the socket package") end
    port = port or 514
    local fmt = opts.formatter or M.formatter.syslog
    local sock = socket.udp.new()
    return {
        write = function(self, rec)
            local line = fmt(rec, opts)
            pcall(function() sock:send_to(line, host, port) end)
        end,
        close = function(self) pcall(function() sock:close() end) end,
    }
end

-- HTTP sink: batches records, flushes on count or interval. Targets a single
-- URL via POST. Parses url into host/port/path so we can drive sockets directly.
local function parse_url(url)
    local scheme, host, port, path = url:match("^(https?)://([^:/]+):?(%d*)(/?.*)$")
    if not scheme then error("log.sink.http: bad url " .. tostring(url)) end
    port = port ~= "" and tonumber(port) or (scheme == "https" and 443 or 80)
    if path == "" then path = "/" end
    return scheme, host, port, path
end

function M.sink.http(url, opts)
    opts = opts or {}
    if not socket then error("log.sink.http requires the socket package") end
    local scheme, host, port, path = parse_url(url)
    if scheme == "https" then
        -- TLS would require tls_client integration; for now we refuse rather
        -- than silently downgrade -- log delivery to https is security-relevant.
        error("log.sink.http: https not supported; use http:// or run a sidecar")
    end
    local fmt = opts.formatter or M.formatter.json
    local batch_n = opts.batch or 16
    local flush_ms = opts.flush_ms or 1000
    local headers = opts.headers or {}

    local sink = { _batch = {}, _last_flush = now_seconds() * 1000 }

    local function build_request(body)
        local hdr_lines = {
            "POST " .. path .. " HTTP/1.1",
            "Host: " .. host,
            "Content-Type: application/x-ndjson",
            "Content-Length: " .. #body,
            "Connection: close",
        }
        for k, v in pairs(headers) do hdr_lines[#hdr_lines + 1] = k .. ": " .. v end
        return table.concat(hdr_lines, "\r\n") .. "\r\n\r\n" .. body
    end

    local function flush(self)
        if #self._batch == 0 then return end
        local body = table.concat(self._batch, "\n")
        self._batch = {}
        self._last_flush = now_seconds() * 1000
        pcall(function()
            local sock = socket.tcp.connect(host, port, { timeout_ms = 1000 })
            sock:set_timeout(2000)
            sock:write(build_request(body))
            sock:close()
        end)
    end

    function sink:write(rec)
        self._batch[#self._batch + 1] = fmt(rec, opts)
        local elapsed = now_seconds() * 1000 - self._last_flush
        if #self._batch >= batch_n or elapsed >= flush_ms then flush(self) end
    end

    function sink:close() flush(sink) end
    sink.flush = flush

    return sink
end

-- ===== Sampling =========================================================

M.sample = {}

function M.sample.percent(p)
    -- p in [0,1]. Fatal records bypass sampling -- we still want to see crashes.
    return function(rec)
        if rec.level == "fatal" or rec.level == "error" then return true end
        return math.random() < p
    end
end

function M.sample.ratelimit(per_sec)
    -- Token bucket. capacity == per_sec so a burst can use all of one second.
    local tokens, last = per_sec, now_seconds()
    return function(rec)
        if rec.level == "fatal" or rec.level == "error" then return true end
        local now = now_seconds()
        tokens = math.min(per_sec, tokens + (now - last) * per_sec)
        last = now
        if tokens >= 1 then tokens = tokens - 1; return true end
        return false
    end
end

-- ===== Logger ===========================================================

local Logger = {}
Logger.__index = Logger

function Logger:set_level(l)
    self._min_level = level_num(l)
    return self
end

function Logger:add_sink(sink)
    self._sinks[#self._sinks + 1] = sink
    return self
end

function Logger:add_sampler(fn)
    self._samplers[#self._samplers + 1] = fn
    return self
end

function Logger:with(extra)
    -- Child shares sinks/samplers but extends fields. Cheap copy: shallow
    -- merge is enough because callers shouldn't mutate field tables anyway.
    local merged = {}
    if self._fields then for k, v in pairs(self._fields) do merged[k] = v end end
    for k, v in pairs(extra) do merged[k] = v end
    return setmetatable({
        _name      = self._name,
        _min_level = self._min_level,
        _sinks     = self._sinks,
        _samplers  = self._samplers,
        _source    = self._source,
        _fields    = merged,
    }, Logger)
end

local function capture_source(skip)
    -- skip counts: 1 = this fn, 2 = log-level method, 3 = user call site.
    if not debug or not debug.getinfo then return nil end
    local info = debug.getinfo(skip, "Sln")
    if not info then return nil end
    return {
        file = info.short_src or info.source or "?",
        line = info.currentline or 0,
        func = info.name,
    }
end

local function emit(self, level_name, msg, fields)
    if level_num(level_name) < self._min_level then return end
    -- Merge per-logger context with per-call fields. Per-call wins on collision.
    local f = nil
    if self._fields or fields then
        f = {}
        if self._fields then for k, v in pairs(self._fields) do f[k] = v end end
        if fields then for k, v in pairs(fields) do f[k] = v end end
    end
    local rec = {
        ts     = now_seconds(),
        level  = level_name,
        msg    = msg,
        fields = f,
        logger = self._name,
    }
    if self._source then rec.source = capture_source(4) end
    -- Sampling: if ANY sampler drops, the record is gone. We don't try to
    -- per-sink sample; that's a job for a dedicated wrapper sink if needed.
    for i = 1, #self._samplers do
        if not self._samplers[i](rec) then return end
    end
    for i = 1, #self._sinks do
        local ok, err = pcall(self._sinks[i].write, self._sinks[i], rec)
        if not ok then
            -- Last-resort: write to stderr so a broken sink is visible.
            io.stderr:write("log: sink error: " .. tostring(err) .. "\n")
        end
    end
end

function Logger:trace(msg, fields) emit(self, "trace", msg, fields) end
function Logger:debug(msg, fields) emit(self, "debug", msg, fields) end
function Logger:info(msg, fields)  emit(self, "info",  msg, fields) end
function Logger:warn(msg, fields)  emit(self, "warn",  msg, fields) end
function Logger:error(msg, fields) emit(self, "error", msg, fields) end
function Logger:fatal(msg, fields) emit(self, "fatal", msg, fields) end

function Logger:log(level, msg, fields) emit(self, level, msg, fields) end

function Logger:close()
    for i = 1, #self._sinks do
        if self._sinks[i].close then pcall(self._sinks[i].close, self._sinks[i]) end
    end
end

-- ===== Constructor ======================================================

function M.new(opts)
    opts = opts or {}
    local logger = setmetatable({
        _name      = opts.name,
        _min_level = level_num(opts.level or "info"),
        _sinks     = {},
        _samplers  = {},
        _source    = opts.source ~= false,  -- on by default
        _fields    = opts.fields,
    }, Logger)
    if opts.sinks then
        for _, s in ipairs(opts.sinks) do logger:add_sink(s) end
    else
        -- Default: pretty stderr if tty, json stdout otherwise.
        local fmt = (color and color.supports_color and color.supports_color())
            and M.formatter.text or M.formatter.json
        logger:add_sink(M.sink.stderr({ formatter = fmt, flush = true }))
    end
    if opts.samplers then
        for _, s in ipairs(opts.samplers) do logger:add_sampler(s) end
    end
    return logger
end

-- ===== Global default logger ===========================================

local _default = nil
local function default()
    if not _default then _default = M.new({ source = false }) end
    return _default
end

function M.set_default(l) _default = l end
function M.default() return default() end

for _, lvl in ipairs({ "trace", "debug", "info", "warn", "error", "fatal" }) do
    M[lvl] = function(msg, fields) emit(default(), lvl, msg, fields) end
end

function M.with(fields) return default():with(fields) end

return M
