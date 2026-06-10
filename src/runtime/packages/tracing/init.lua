-- tracing -- OpenTelemetry-style distributed tracing.
--
-- Public surface:
--   tracing.tracer(name, opts?)             -> tracer
--   tracer:start(name, opts?)               -> span
--   span:set_attribute(k, v)
--   span:add_event(name, attrs?)
--   span:set_status("ok"|"error", msg?)
--   span:end_()                             -> records to provider
--   tracing.with_span(name, fn, opts?)      -> result of fn (auto end)
--   tracing.propagate(headers, span)        -> mutates headers, injects traceparent
--   tracing.extract(headers)                -> { trace_id, span_id, sampled } or nil
--   tracing.provider({exporter=, sampler=}) -> provider (set with set_default_provider)
--
-- Exporters:
--   tracing.exporter.stdout_json()
--   tracing.exporter.otlp_http(url, opts?)
--   tracing.exporter.jaeger_http(url, opts?)
--   tracing.exporter.zipkin_http(url, opts?)
--
-- Samplers:
--   tracing.sampler.always()
--   tracing.sampler.never()
--   tracing.sampler.ratio(p)
--   tracing.sampler.parent_or(ratio_p)      -- respect parent decision when present
--
-- The provider is the seam between span emission and shipping. A span's
-- :end_() pushes the finished span to its tracer's provider, which forwards
-- to the configured exporter. Exporters do their own batching/flushing.

local M = {}

local json   = (function() local ok, m = pcall(require, "json"); return ok and m or nil end)()
local socket = (function() local ok, m = pcall(require, "socket"); return ok and m or nil end)()

-- ===== ID generation ====================================================
--
-- W3C trace_id is 16 bytes (128 bits), span_id is 8 bytes (64 bits). Render
-- as lowercase hex. We use math.random; this is fine for trace IDs in a
-- non-adversarial telemetry pipeline.

local function rand_hex(n_bytes)
    local parts = {}
    for i = 1, n_bytes do
        parts[i] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(parts)
end

local function gen_trace_id() return rand_hex(16) end
local function gen_span_id()  return rand_hex(8)  end

-- ===== Time helpers =====================================================

local function now_ns()
    -- We synthesize nanoseconds from os.time() + os.clock() fraction. That's
    -- not real ns precision, but it's monotonic-within-process and good
    -- enough for downstream tools that just diff start/end.
    local sec = os.time()
    local frac = os.clock() % 1
    return math.floor((sec + frac) * 1e9)
end

-- ===== Samplers =========================================================

M.sampler = {}

function M.sampler.always() return function() return true end end
function M.sampler.never()  return function() return false end end

function M.sampler.ratio(p)
    return function() return math.random() < p end
end

function M.sampler.parent_or(p)
    -- Honor the parent's sampling bit if there is one, else flip a coin.
    return function(ctx)
        if ctx and ctx.parent and ctx.parent.sampled ~= nil then return ctx.parent.sampled end
        return math.random() < p
    end
end

-- ===== HTTP helper (minimal POST) =======================================

local function parse_url(url)
    local scheme, host, port, path = url:match("^(https?)://([^:/]+):?(%d*)(/?.*)$")
    if not scheme then error("tracing: bad URL " .. tostring(url)) end
    port = port ~= "" and tonumber(port) or (scheme == "https" and 443 or 80)
    if path == "" then path = "/" end
    return scheme, host, port, path
end

local function http_post(url, body, headers, content_type)
    if not socket then return false, "socket package unavailable" end
    local scheme, host, port, path = parse_url(url)
    if scheme == "https" then return false, "https not supported" end
    local hdr = {
        "POST " .. path .. " HTTP/1.1",
        "Host: " .. host,
        "Content-Type: " .. (content_type or "application/json"),
        "Content-Length: " .. #body,
        "Connection: close",
    }
    if headers then
        for k, v in pairs(headers) do hdr[#hdr + 1] = k .. ": " .. v end
    end
    local req = table.concat(hdr, "\r\n") .. "\r\n\r\n" .. body
    local ok, err = pcall(function()
        local sock = socket.tcp.connect(host, port, { timeout_ms = 1000 })
        sock:set_timeout(2000)
        sock:write(req)
        sock:close()
    end)
    return ok, err
end

-- ===== Exporters ========================================================

M.exporter = {}

function M.exporter.stdout_json()
    return {
        export = function(self, spans)
            for i = 1, #spans do
                local rec = {
                    name      = spans[i].name,
                    trace_id  = spans[i].trace_id,
                    span_id   = spans[i].span_id,
                    parent_id = spans[i].parent_span_id,
                    start_ns  = spans[i].start_ns,
                    end_ns    = spans[i].end_ns,
                    attrs     = spans[i].attributes,
                    events    = spans[i].events,
                    status    = spans[i].status,
                    kind      = spans[i].kind,
                }
                if json then
                    io.stdout:write(json.encode(rec), "\n")
                else
                    io.stdout:write(tostring(rec), "\n")
                end
            end
        end,
        shutdown = function() end,
    }
end

-- OTLP/HTTP -- OpenTelemetry's JSON wire encoding. We post a single
-- ResourceSpans payload per call. Some collectors prefer protobuf; the JSON
-- mode is documented at /v1/traces and is the path of least resistance.
function M.exporter.otlp_http(url, opts)
    opts = opts or {}
    local headers = opts.headers or {}
    return {
        export = function(self, spans)
            if not json then return end
            local otlp_spans = {}
            for i = 1, #spans do
                local s = spans[i]
                local attrs = {}
                if s.attributes then
                    for k, v in pairs(s.attributes) do
                        attrs[#attrs + 1] = { key = k, value = { stringValue = tostring(v) } }
                    end
                end
                local events = {}
                if s.events then
                    for j = 1, #s.events do
                        local e = s.events[j]
                        local eattrs = {}
                        if e.attrs then
                            for k, v in pairs(e.attrs) do
                                eattrs[#eattrs + 1] = { key = k, value = { stringValue = tostring(v) } }
                            end
                        end
                        events[#events + 1] = {
                            name = e.name, timeUnixNano = tostring(e.ts_ns), attributes = eattrs,
                        }
                    end
                end
                local status_code = 0
                if s.status and s.status.code == "error" then status_code = 2
                elseif s.status and s.status.code == "ok" then status_code = 1 end
                otlp_spans[#otlp_spans + 1] = {
                    traceId = s.trace_id, spanId = s.span_id,
                    parentSpanId = s.parent_span_id or "",
                    name = s.name,
                    kind = 1,
                    startTimeUnixNano = tostring(s.start_ns),
                    endTimeUnixNano   = tostring(s.end_ns),
                    attributes = attrs,
                    events     = events,
                    status     = { code = status_code, message = s.status and s.status.message or "" },
                }
            end
            local payload = {
                resourceSpans = {{
                    resource = { attributes = {
                        { key = "service.name", value = { stringValue = opts.service or "lua" } },
                    }},
                    scopeSpans = {{ spans = otlp_spans }},
                }},
            }
            http_post(url, json.encode(payload), headers, "application/json")
        end,
        shutdown = function() end,
    }
end

-- Jaeger HTTP (Thrift-over-HTTP collector at /api/traces). Spec accepts a
-- simpler JSON variant when content-type is application/json; we use that.
function M.exporter.jaeger_http(url, opts)
    opts = opts or {}
    local headers = opts.headers or {}
    return {
        export = function(self, spans)
            if not json then return end
            local jspans = {}
            for i = 1, #spans do
                local s = spans[i]
                local tags = {}
                if s.attributes then
                    for k, v in pairs(s.attributes) do
                        tags[#tags + 1] = { key = k, type = "string", value = tostring(v) }
                    end
                end
                local refs = {}
                if s.parent_span_id then
                    refs[#refs + 1] = { refType = "CHILD_OF",
                        traceID = s.trace_id, spanID = s.parent_span_id }
                end
                jspans[#jspans + 1] = {
                    traceID       = s.trace_id,
                    spanID        = s.span_id,
                    operationName = s.name,
                    startTime     = math.floor(s.start_ns / 1000),  -- jaeger uses microseconds
                    duration      = math.floor((s.end_ns - s.start_ns) / 1000),
                    tags          = tags,
                    references    = refs,
                }
            end
            local payload = {
                data = {{
                    traceID   = spans[1] and spans[1].trace_id or "",
                    spans     = jspans,
                    processes = {},
                }},
            }
            http_post(url, json.encode(payload), headers, "application/json")
        end,
        shutdown = function() end,
    }
end

-- Zipkin v2 JSON. Array of spans with id, traceId, parentId, name, kind,
-- timestamp (microseconds), duration (microseconds), tags.
function M.exporter.zipkin_http(url, opts)
    opts = opts or {}
    local headers = opts.headers or {}
    return {
        export = function(self, spans)
            if not json then return end
            local zspans = {}
            for i = 1, #spans do
                local s = spans[i]
                local tags = {}
                if s.attributes then
                    for k, v in pairs(s.attributes) do tags[k] = tostring(v) end
                end
                zspans[#zspans + 1] = {
                    traceId        = s.trace_id,
                    id             = s.span_id,
                    parentId       = s.parent_span_id,
                    name           = s.name,
                    kind           = "INTERNAL",
                    timestamp      = math.floor(s.start_ns / 1000),
                    duration       = math.floor((s.end_ns - s.start_ns) / 1000),
                    tags           = tags,
                    localEndpoint  = { serviceName = opts.service or "lua" },
                }
            end
            http_post(url, json.encode(zspans), headers, "application/json")
        end,
        shutdown = function() end,
    }
end

-- ===== Provider =========================================================

local Provider = {}
Provider.__index = Provider

function Provider:on_end(span)
    -- Sampling gate: if span isn't sampled, drop on the floor.
    if not span._sampled then return end
    self._buf[#self._buf + 1] = span
    if #self._buf >= self._batch then self:flush() end
end

function Provider:flush()
    if #self._buf == 0 then return end
    local batch = self._buf
    self._buf = {}
    if self._exporter and self._exporter.export then
        pcall(function() self._exporter:export(batch) end)
    end
end

function Provider:shutdown()
    self:flush()
    if self._exporter and self._exporter.shutdown then
        pcall(function() self._exporter:shutdown() end)
    end
end

function M.provider(opts)
    opts = opts or {}
    return setmetatable({
        _exporter = opts.exporter or M.exporter.stdout_json(),
        _sampler  = opts.sampler  or M.sampler.always(),
        _batch    = opts.batch_size or 1,  -- 1 = flush per span; raise for throughput
        _buf      = {},
    }, Provider)
end

local _default_provider = nil
function M.set_default_provider(p) _default_provider = p end
local function default_provider()
    if not _default_provider then _default_provider = M.provider() end
    return _default_provider
end
M.default_provider = default_provider

-- ===== Span / Tracer ====================================================

local Span = {}
Span.__index = Span

function Span:set_attribute(k, v)
    self.attributes = self.attributes or {}
    self.attributes[k] = v
    return self
end

function Span:add_event(name, attrs)
    self.events = self.events or {}
    self.events[#self.events + 1] = { name = name, attrs = attrs, ts_ns = now_ns() }
    return self
end

function Span:set_status(code, message)
    self.status = { code = code, message = message }
    return self
end

function Span:end_(opts)
    if self.end_ns then return end  -- guard double-end
    self.end_ns = (opts and opts.end_ns) or now_ns()
    self._provider:on_end(self)
end

-- Lua doesn't let us name a method `end` (reserved keyword); _end_ stays
-- callable; we also expose finish() as an alias for ergonomic chaining.
function Span:finish(opts) return self:end_(opts) end

-- Use this as ctx.current_span when calling tracer:start to make the new
-- span a child of `self`. Doubles as W3C-context shim for propagate/extract.
function Span:context()
    return {
        trace_id = self.trace_id,
        span_id  = self.span_id,
        sampled  = self._sampled,
    }
end

local Tracer = {}
Tracer.__index = Tracer

function Tracer:start(name, opts)
    opts = opts or {}
    local provider = self._provider or default_provider()
    local parent_ctx = opts.parent
    -- If parent is a Span object, lift its context.
    if parent_ctx and parent_ctx.context and type(parent_ctx.context) == "function" then
        parent_ctx = parent_ctx:context()
    end
    local trace_id = parent_ctx and parent_ctx.trace_id or gen_trace_id()
    local span_id  = gen_span_id()
    local sampled = provider._sampler({ parent = parent_ctx })

    local span = setmetatable({
        name           = name,
        kind           = opts.kind or "internal",
        tracer_name    = self._name,
        trace_id       = trace_id,
        span_id        = span_id,
        parent_span_id = parent_ctx and parent_ctx.span_id,
        start_ns       = now_ns(),
        end_ns         = nil,
        attributes     = opts.attributes,
        events         = nil,
        status         = nil,
        _sampled       = sampled,
        _provider      = provider,
    }, Span)
    return span
end

function M.tracer(name, opts)
    opts = opts or {}
    return setmetatable({
        _name     = name,
        _provider = opts.provider,
    }, Tracer)
end

-- ===== with_span: scope-managed span ====================================

function M.with_span(name, fn, opts)
    opts = opts or {}
    local tracer = opts.tracer or M.tracer(opts.tracer_name or "default")
    local span = tracer:start(name, opts)
    -- pcall so an error inside fn still ends the span with status=error.
    local ok, result = pcall(fn, span)
    if ok then
        span:set_status("ok")
    else
        span:set_status("error", tostring(result))
    end
    span:end_()
    if not ok then error(result, 2) end
    return result
end

-- ===== W3C Trace Context propagation ====================================
--
-- Header format: traceparent: 00-<trace_id>-<span_id>-<flags>
-- Flags is two hex chars; bit 0 == sampled.

function M.propagate(headers, span_or_ctx)
    headers = headers or {}
    local ctx = span_or_ctx
    if ctx and ctx.context and type(ctx.context) == "function" then ctx = ctx:context() end
    if not ctx or not ctx.trace_id or not ctx.span_id then return headers end
    local flags = ctx.sampled and "01" or "00"
    headers.traceparent = string.format("00-%s-%s-%s", ctx.trace_id, ctx.span_id, flags)
    return headers
end

function M.extract(headers)
    if not headers then return nil end
    local tp = headers.traceparent or headers.Traceparent or headers.TRACEPARENT
    if not tp then return nil end
    local ver, trace_id, span_id, flags = tp:match("^(%x%x)%-(%x+)%-(%x+)%-(%x%x)$")
    if not ver then return nil end
    if #trace_id ~= 32 or #span_id ~= 16 then return nil end
    return {
        trace_id = trace_id,
        span_id  = span_id,
        sampled  = (tonumber(flags, 16) or 0) % 2 == 1,
    }
end

return M
