-- metrics -- Prometheus/StatsD-style metric registry.
--
-- Public surface:
--   metrics.counter(name, opts?)            -> counter
--   metrics.gauge(name, opts?)              -> gauge
--   metrics.histogram(name, opts?)          -> histogram   (opts.buckets = {0.005,0.01,...})
--   metrics.summary(name, opts?)            -> summary     (opts.quantiles = {0.5,0.9,...})
--   metrics.register(metric)                -> add to default registry
--   metrics.gather()                        -> list of metrics
--   metrics.prom_format()                   -> Prometheus exposition text
--   metrics.statsd_send(host, port)         -> push gauges/counters as datagrams
--   metrics.registry()                      -> new isolated registry
--
-- All metric ctors take opts.labels = {"method","status"} to declare the label
-- schema. Per-series resolution via metric:labels({method="GET",status="200"})
-- which returns a child metric bound to that label set.

local M = {}

local socket = (function() local ok, m = pcall(require, "socket"); return ok and m or nil end)()

-- ===== Help: a stable label key from a label table ======================

local function label_key(labels, names)
    -- Produce "method=GET,status=200" with sorted-by-schema key order so
    -- two equivalent label tables hash to the same bucket.
    if not names or #names == 0 then return "" end
    local parts = {}
    for i = 1, #names do
        local n = names[i]
        parts[i] = n .. "=" .. tostring(labels and labels[n] or "")
    end
    return table.concat(parts, ",")
end

-- Escape a label value for the Prometheus text format.
local function prom_label_escape(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
    return s
end

local function prom_render_labels(labels, names)
    if not names or #names == 0 then return "" end
    local parts = {}
    for i = 1, #names do
        local n = names[i]
        parts[#parts + 1] = string.format('%s="%s"', n, prom_label_escape(labels[n] or ""))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- A metric is identified by name + label schema. Each series (specific label
-- values) lives in metric._series keyed by label_key. This split mirrors
-- Prometheus's mental model: one "MetricFamily" with many child time-series.

-- ===== Counter ==========================================================

local Counter = {}
Counter.__index = Counter

function Counter:_series_for(labels)
    local k = label_key(labels, self._label_names)
    local s = self._series[k]
    if not s then
        s = { labels = labels or {}, value = 0 }
        self._series[k] = s
    end
    return s
end

function Counter:inc(n)
    -- A bare inc() bumps the no-labels series. Counters never go down.
    local s = self:_series_for(nil)
    n = n or 1
    if n < 0 then error("metrics.counter:inc(n) requires n >= 0") end
    s.value = s.value + n
end

function Counter:add(n) self:inc(n) end

function Counter:labels(labels)
    -- Returns a "bound" view: same metric metadata, just a stable label set.
    -- A bound view supports :inc/:add/:value without re-passing labels.
    -- We deliberately don't inherit Counter's metatable -- a labelled view
    -- shouldn't expose :labels again (it would lose track of label_names).
    local s = self:_series_for(labels)
    return {
        _parent = self,
        _series = s,
        inc = function(self2, n)
            n = n or 1
            if n < 0 then error("counter:inc requires n >= 0") end
            self2._series.value = self2._series.value + n
        end,
        add = function(self2, n) self2:inc(n) end,
        value = function(self2) return self2._series.value end,
    }
end

function Counter:value(labels)
    if labels then return self:_series_for(labels).value end
    return self._series[""] and self._series[""].value or 0
end

function M.counter(name, opts)
    opts = opts or {}
    return setmetatable({
        _kind        = "counter",
        _name        = name,
        _help        = opts.help or "",
        _label_names = opts.labels or {},
        _series      = {},
    }, Counter)
end

-- ===== Gauge ============================================================

local Gauge = {}
Gauge.__index = Gauge

function Gauge:_series_for(labels)
    local k = label_key(labels, self._label_names)
    local s = self._series[k]
    if not s then
        s = { labels = labels or {}, value = 0 }
        self._series[k] = s
    end
    return s
end

function Gauge:set(v) self:_series_for(nil).value = v end
function Gauge:inc(n) self:_series_for(nil).value = self:_series_for(nil).value + (n or 1) end
function Gauge:dec(n) self:_series_for(nil).value = self:_series_for(nil).value - (n or 1) end

function Gauge:labels(labels)
    local s = self:_series_for(labels)
    return {
        _parent = self,
        _series = s,
        set = function(self2, v) self2._series.value = v end,
        inc = function(self2, n) self2._series.value = self2._series.value + (n or 1) end,
        dec = function(self2, n) self2._series.value = self2._series.value - (n or 1) end,
        value = function(self2) return self2._series.value end,
    }
end

function Gauge:value(labels)
    if labels then return self:_series_for(labels).value end
    return self._series[""] and self._series[""].value or 0
end

function M.gauge(name, opts)
    opts = opts or {}
    return setmetatable({
        _kind        = "gauge",
        _name        = name,
        _help        = opts.help or "",
        _label_names = opts.labels or {},
        _series      = {},
    }, Gauge)
end

-- ===== Histogram ========================================================

local DEFAULT_BUCKETS = { 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 }

local Histogram = {}
Histogram.__index = Histogram

local function new_hist_series(buckets, labels)
    local counts = {}
    for i = 1, #buckets do counts[i] = 0 end
    return { labels = labels or {}, counts = counts, sum = 0, count = 0 }
end

function Histogram:_series_for(labels)
    local k = label_key(labels, self._label_names)
    local s = self._series[k]
    if not s then
        s = new_hist_series(self._buckets, labels)
        self._series[k] = s
    end
    return s
end

local function hist_observe(s, buckets, v)
    s.sum = s.sum + v
    s.count = s.count + 1
    -- Linear walk is fine: typical bucket count is <= 16.
    for i = 1, #buckets do
        if v <= buckets[i] then s.counts[i] = s.counts[i] + 1 end
    end
end

function Histogram:observe(v) hist_observe(self:_series_for(nil), self._buckets, v) end

function Histogram:labels(labels)
    local s = self:_series_for(labels)
    return {
        _parent = self,
        _series = s,
        observe = function(self2, v) hist_observe(self2._series, self2._parent._buckets, v) end,
    }
end

function M.histogram(name, opts)
    opts = opts or {}
    return setmetatable({
        _kind        = "histogram",
        _name        = name,
        _help        = opts.help or "",
        _label_names = opts.labels or {},
        _buckets     = opts.buckets or DEFAULT_BUCKETS,
        _series      = {},
    }, Histogram)
end

-- ===== Summary ==========================================================
--
-- Approximate quantiles via reservoir sampling. True streaming q-digest is
-- overkill for the kinds of workloads Lua summarizes; a sample-based estimate
-- is honest and cheap.

local DEFAULT_QUANTILES = { 0.5, 0.9, 0.99 }
local DEFAULT_RESERVOIR = 1024

local Summary = {}
Summary.__index = Summary

local function new_summary_series(reservoir_size, labels)
    return {
        labels = labels or {},
        reservoir = {},
        reservoir_size = reservoir_size,
        seen = 0,
        sum = 0,
        count = 0,
    }
end

function Summary:_series_for(labels)
    local k = label_key(labels, self._label_names)
    local s = self._series[k]
    if not s then
        s = new_summary_series(self._reservoir_size, labels)
        self._series[k] = s
    end
    return s
end

local function summary_observe(s, v)
    s.sum = s.sum + v
    s.count = s.count + 1
    s.seen = s.seen + 1
    if #s.reservoir < s.reservoir_size then
        s.reservoir[#s.reservoir + 1] = v
    else
        -- Algorithm R: replace with prob k/n -- keeps a uniform sample.
        local idx = math.random(1, s.seen)
        if idx <= s.reservoir_size then s.reservoir[idx] = v end
    end
end

local function summary_quantile(s, q)
    if #s.reservoir == 0 then return 0 end
    -- Sort lazily into a scratch copy so quantile calls don't mutate the
    -- reservoir ordering (which would break Algorithm R's bookkeeping).
    local sorted = {}
    for i = 1, #s.reservoir do sorted[i] = s.reservoir[i] end
    table.sort(sorted)
    local idx = math.max(1, math.min(#sorted, math.ceil(q * #sorted)))
    return sorted[idx]
end

function Summary:observe(v) summary_observe(self:_series_for(nil), v) end

function Summary:quantile(q, labels) return summary_quantile(self:_series_for(labels), q) end

function Summary:labels(labels)
    local s = self:_series_for(labels)
    return {
        _parent = self,
        _series = s,
        observe = function(self2, v) summary_observe(self2._series, v) end,
        quantile = function(self2, q) return summary_quantile(self2._series, q) end,
    }
end

function M.summary(name, opts)
    opts = opts or {}
    return setmetatable({
        _kind           = "summary",
        _name           = name,
        _help           = opts.help or "",
        _label_names    = opts.labels or {},
        _quantiles      = opts.quantiles or DEFAULT_QUANTILES,
        _reservoir_size = opts.reservoir or DEFAULT_RESERVOIR,
        _series         = {},
    }, Summary)
end

-- ===== Registry =========================================================

local function new_registry()
    return {
        _metrics = {},
        register = function(self, m)
            -- Reject duplicates: surfacing collisions early beats silent merging.
            for i = 1, #self._metrics do
                if self._metrics[i]._name == m._name then
                    error("metrics.register: duplicate name " .. m._name)
                end
            end
            self._metrics[#self._metrics + 1] = m
            return m
        end,
        unregister = function(self, name)
            for i = 1, #self._metrics do
                if self._metrics[i]._name == name then
                    table.remove(self._metrics, i)
                    return true
                end
            end
            return false
        end,
        gather = function(self)
            local out = {}
            for i = 1, #self._metrics do out[i] = self._metrics[i] end
            return out
        end,
    }
end

local _default = new_registry()

function M.registry() return new_registry() end
function M.register(metric) return _default:register(metric) end
function M.unregister(name) return _default:unregister(name) end
function M.gather() return _default:gather() end
function M.reset() _default = new_registry() end

-- ===== Prometheus exposition format =====================================

local function prom_metric_lines(m, out)
    local kind = m._kind
    out[#out + 1] = "# HELP " .. m._name .. " " .. (m._help or "")
    -- Map summary -> "summary", histogram -> "histogram", others as-is.
    out[#out + 1] = "# TYPE " .. m._name .. " " .. kind

    if kind == "counter" or kind == "gauge" then
        for _, s in pairs(m._series) do
            local lbls = prom_render_labels(s.labels, m._label_names)
            out[#out + 1] = m._name .. lbls .. " " .. tostring(s.value)
        end

    elseif kind == "histogram" then
        for _, s in pairs(m._series) do
            for i = 1, #m._buckets do
                local lbls = s.labels or {}
                -- Cumulative count for each le bucket.
                local with_le = {}
                for k, v in pairs(lbls) do with_le[k] = v end
                with_le.le = tostring(m._buckets[i])
                local merged_names = {}
                for _, n in ipairs(m._label_names) do merged_names[#merged_names + 1] = n end
                merged_names[#merged_names + 1] = "le"
                local lbl_str = prom_render_labels(with_le, merged_names)
                out[#out + 1] = m._name .. "_bucket" .. lbl_str .. " " .. tostring(s.counts[i])
            end
            -- The "+Inf" bucket is always the total count.
            local with_le = {}
            for k, v in pairs(s.labels or {}) do with_le[k] = v end
            with_le.le = "+Inf"
            local merged_names = {}
            for _, n in ipairs(m._label_names) do merged_names[#merged_names + 1] = n end
            merged_names[#merged_names + 1] = "le"
            out[#out + 1] = m._name .. "_bucket" .. prom_render_labels(with_le, merged_names)
                .. " " .. tostring(s.count)
            local plain = prom_render_labels(s.labels or {}, m._label_names)
            out[#out + 1] = m._name .. "_sum"   .. plain .. " " .. tostring(s.sum)
            out[#out + 1] = m._name .. "_count" .. plain .. " " .. tostring(s.count)
        end

    elseif kind == "summary" then
        for _, s in pairs(m._series) do
            for _, q in ipairs(m._quantiles) do
                local with_q = {}
                for k, v in pairs(s.labels or {}) do with_q[k] = v end
                with_q.quantile = tostring(q)
                local merged_names = {}
                for _, n in ipairs(m._label_names) do merged_names[#merged_names + 1] = n end
                merged_names[#merged_names + 1] = "quantile"
                out[#out + 1] = m._name
                    .. prom_render_labels(with_q, merged_names)
                    .. " " .. tostring(summary_quantile(s, q))
            end
            local plain = prom_render_labels(s.labels or {}, m._label_names)
            out[#out + 1] = m._name .. "_sum"   .. plain .. " " .. tostring(s.sum)
            out[#out + 1] = m._name .. "_count" .. plain .. " " .. tostring(s.count)
        end
    end
end

function M.prom_format(reg)
    reg = reg or _default
    local out = {}
    for _, m in ipairs(reg:gather()) do prom_metric_lines(m, out) end
    out[#out + 1] = ""  -- trailing newline per text-format convention
    return table.concat(out, "\n")
end

-- ===== StatsD export ====================================================
--
-- StatsD wire format (one metric per UDP packet, datagram-sized for safety):
--   <name>:<value>|<type>[|@<sample_rate>][|#tag1:v1,tag2:v2]
-- Types we emit:
--   counter -> "c"
--   gauge   -> "g"
--   histogram observations are not stored individually; we emit sum+count.
--   summary likewise.

local function statsd_tags(labels, names)
    if not names or #names == 0 then return "" end
    local parts = {}
    for i = 1, #names do
        parts[#parts + 1] = names[i] .. ":" .. tostring(labels[names[i]] or "")
    end
    return "|#" .. table.concat(parts, ",")
end

function M.statsd_lines(reg)
    reg = reg or _default
    local out = {}
    for _, m in ipairs(reg:gather()) do
        if m._kind == "counter" then
            for _, s in pairs(m._series) do
                out[#out + 1] = string.format("%s:%s|c%s",
                    m._name, tostring(s.value), statsd_tags(s.labels, m._label_names))
            end
        elseif m._kind == "gauge" then
            for _, s in pairs(m._series) do
                out[#out + 1] = string.format("%s:%s|g%s",
                    m._name, tostring(s.value), statsd_tags(s.labels, m._label_names))
            end
        elseif m._kind == "histogram" or m._kind == "summary" then
            for _, s in pairs(m._series) do
                out[#out + 1] = string.format("%s_sum:%s|g%s",
                    m._name, tostring(s.sum), statsd_tags(s.labels, m._label_names))
                out[#out + 1] = string.format("%s_count:%s|c%s",
                    m._name, tostring(s.count), statsd_tags(s.labels, m._label_names))
            end
        end
    end
    return out
end

function M.statsd_send(host, port, reg)
    if not socket then error("metrics.statsd_send requires the socket package") end
    port = port or 8125
    local sock = socket.udp.new()
    local lines = M.statsd_lines(reg)
    for i = 1, #lines do
        -- Best-effort -- StatsD is fire-and-forget UDP by design.
        pcall(function() sock:send_to(lines[i], host, port) end)
    end
    sock:close()
    return #lines
end

-- ===== Timing helper ====================================================

function M.time(histogram_or_summary, fn)
    -- Wraps fn so we observe its wall-clock duration into a histogram/summary.
    -- Useful for the most common metric idiom; avoids littering callers with
    -- start/stop bookkeeping.
    local t0 = os.clock()
    local results = { fn() }
    histogram_or_summary:observe(os.clock() - t0)
    return table.unpack(results)
end

return M
