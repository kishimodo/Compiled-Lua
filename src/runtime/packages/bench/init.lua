-- bench -- microbenchmark framework with statistical reporting.
--
-- Public surface:
--   bench.bench(name, fn, opts?)       -> result
--   bench.compare({a=fn1, b=fn2, ...}, opts?) -> sorted result table
--   bench.suite()                      -> suite with :add(name, fn, opts?), :run(), :report()
--   bench.format(result)               -> human-readable text
--
-- Result shape:
--   { name=, iterations=, ns_per_op=, ops_per_sec=,
--     mean_ns=, median_ns=, stddev_ns=, min_ns=, max_ns=,
--     allocs_kb_per_op=, samples=N, outliers=K }
--
-- Style: a "run" is a single execution of fn. We batch runs into "trials"
-- and time the trial as a whole to amortize timing overhead. Each trial
-- yields one data point: ns_per_op = elapsed / batch_size. We collect
-- several trials so we can do real statistics (median, stddev, MAD outlier
-- rejection) instead of just averaging.

local M = {}

-- ===== Timing primitives ===============================================
--
-- os.clock() returns CPU seconds since process start. Resolution varies
-- per platform but is at least microsecond on modern Windows. We assume
-- monotonicity within the benchmark window, which holds in practice even
-- if not strictly guaranteed.

local function clock_ns()
    return os.clock() * 1e9
end

-- ===== Statistics =======================================================

local function stats_summary(samples)
    local n = #samples
    if n == 0 then return { mean = 0, median = 0, stddev = 0, min = 0, max = 0 } end
    -- Mean + min/max in one pass.
    local sum, mn, mx = 0, samples[1], samples[1]
    for i = 1, n do
        local v = samples[i]
        sum = sum + v
        if v < mn then mn = v end
        if v > mx then mx = v end
    end
    local mean = sum / n
    -- Stddev (population). Use Welford-style two-pass for stability when
    -- the spread is small relative to the mean.
    local sqsum = 0
    for i = 1, n do
        local d = samples[i] - mean
        sqsum = sqsum + d * d
    end
    local stddev = math.sqrt(sqsum / n)
    -- Median via sorted copy.
    local sorted = {}
    for i = 1, n do sorted[i] = samples[i] end
    table.sort(sorted)
    local median = (n % 2 == 1)
        and sorted[(n + 1) // 2]
        or  (sorted[n // 2] + sorted[n // 2 + 1]) / 2
    return { mean = mean, median = median, stddev = stddev,
        min = mn, max = mx, sorted = sorted }
end

-- Reject extreme outliers using median-absolute-deviation (Hampel). Anything
-- more than 3 * MAD away from the median is dropped. This handles GC pauses
-- and OS scheduler hiccups without throwing away real variance signal.
local function strip_outliers(samples)
    if #samples < 5 then return samples, 0 end
    local sorted = {}
    for i = 1, #samples do sorted[i] = samples[i] end
    table.sort(sorted)
    local med = sorted[(#sorted + 1) // 2]
    local deviations = {}
    for i = 1, #sorted do deviations[i] = math.abs(sorted[i] - med) end
    table.sort(deviations)
    local mad = deviations[(#deviations + 1) // 2]
    local threshold = math.max(mad * 3, med * 0.01)  -- floor at 1% so we don't get too aggressive
    local kept, dropped = {}, 0
    for i = 1, #samples do
        if math.abs(samples[i] - med) <= threshold then
            kept[#kept + 1] = samples[i]
        else
            dropped = dropped + 1
        end
    end
    if #kept < 3 then return samples, 0 end  -- bailed; not enough to trust
    return kept, dropped
end

-- ===== Calibration =====================================================
--
-- The "auto" iterations heuristic walks the batch size up exponentially
-- until one trial takes at least target_ms. That batch size becomes our
-- per-trial iteration count. From there we run trials until either time
-- elapsed exceeds target_ms again as a soft budget, or we have >= 30
-- samples for a stable distribution.

local function auto_iterations(fn, target_ms)
    local batch = 1
    while true do
        local t0 = clock_ns()
        for _ = 1, batch do fn() end
        local elapsed_ms = (clock_ns() - t0) / 1e6
        if elapsed_ms >= target_ms or batch >= 1e8 then return batch end
        -- 5x growth so we converge fast for very cheap fns.
        batch = batch * 5
    end
end

-- ===== Single bench =====================================================

function M.bench(name, fn, opts)
    opts = opts or {}
    local target_ms = opts.target_ms or 1000
    local warmup    = opts.warmup or 3
    local min_trials = opts.min_trials or 30

    -- Warmup: run fn a few times so JIT/caches stabilize. The Lua VM
    -- doesn't JIT in stock Lua but call-site caches and dispatch warmth
    -- still matter at the microsecond scale.
    for _ = 1, warmup do fn() end

    -- Iterations per trial.
    local iters
    if opts.iterations == nil or opts.iterations == "auto" then
        iters = auto_iterations(fn, opts.batch_ms or 10)
    else
        iters = opts.iterations
    end

    -- Run trials. Track GC counter so we can estimate allocs/op.
    -- collectgarbage("count") returns kilobytes used. Diff before/after
    -- includes some noise but is the best signal we have without
    -- platform-specific hooks.
    local samples = {}
    local kb_deltas = {}
    local trial_budget_ms = math.max(target_ms - 2 * (opts.batch_ms or 10), 100)
    local total_start = clock_ns()

    while true do
        collectgarbage("collect")  -- baseline GC before each trial
        local kb_before = collectgarbage("count")
        local t0 = clock_ns()
        for _ = 1, iters do fn() end
        local elapsed_ns = clock_ns() - t0
        local kb_after = collectgarbage("count")
        samples[#samples + 1] = elapsed_ns / iters
        kb_deltas[#kb_deltas + 1] = (kb_after - kb_before) / iters

        local elapsed_total_ms = (clock_ns() - total_start) / 1e6
        if elapsed_total_ms >= trial_budget_ms and #samples >= min_trials then break end
        if #samples >= (opts.max_trials or 1000) then break end
    end

    local kept, dropped = strip_outliers(samples)
    local s = stats_summary(kept)
    local alloc_s = stats_summary(kb_deltas)

    return {
        name             = name,
        iterations       = iters,
        samples          = #kept,
        outliers         = dropped,
        ns_per_op        = s.median,
        ops_per_sec      = s.median > 0 and 1e9 / s.median or 0,
        mean_ns          = s.mean,
        median_ns        = s.median,
        stddev_ns        = s.stddev,
        min_ns           = s.min,
        max_ns           = s.max,
        rsd_pct          = s.mean > 0 and (s.stddev / s.mean) * 100 or 0,
        allocs_kb_per_op = alloc_s.median,
    }
end

-- ===== Compare =========================================================

function M.compare(fns, opts)
    opts = opts or {}
    local results = {}
    for name, fn in pairs(fns) do
        results[#results + 1] = M.bench(name, fn, opts)
    end
    -- Sort by ns/op ascending (fastest first).
    table.sort(results, function(a, b) return a.ns_per_op < b.ns_per_op end)
    local fastest = results[1] and results[1].ns_per_op or 0
    for i = 1, #results do
        results[i].relative = fastest > 0 and (results[i].ns_per_op / fastest) or 1
    end
    return results
end

-- ===== Suite ===========================================================

local Suite = {}
Suite.__index = Suite

function Suite:add(name, fn, opts)
    self._entries[#self._entries + 1] = { name = name, fn = fn, opts = opts }
    return self
end

function Suite:run()
    self._results = {}
    for i = 1, #self._entries do
        local e = self._entries[i]
        self._results[i] = M.bench(e.name, e.fn, e.opts or self._opts)
    end
    return self._results
end

function Suite:report()
    if not self._results then self:run() end
    local rows = {}
    for i = 1, #self._results do rows[i] = self._results[i] end
    table.sort(rows, function(a, b) return a.ns_per_op < b.ns_per_op end)
    local fastest = rows[1] and rows[1].ns_per_op or 1
    local out = {}
    out[#out + 1] = string.format("%-30s %12s %12s %10s %10s %10s",
        "Name", "ns/op", "ops/sec", "rsd%", "alloc kb/op", "vs fastest")
    out[#out + 1] = string.rep("-", 88)
    for _, r in ipairs(rows) do
        out[#out + 1] = string.format("%-30s %12.2f %12.0f %10.2f %10.4f %10s",
            r.name, r.ns_per_op, r.ops_per_sec, r.rsd_pct,
            r.allocs_kb_per_op or 0,
            string.format("%.2fx", r.ns_per_op / fastest))
    end
    return table.concat(out, "\n")
end

function M.suite(opts)
    return setmetatable({
        _entries = {},
        _results = nil,
        _opts    = opts or {},
    }, Suite)
end

-- ===== Formatter =======================================================

function M.format(result)
    -- Human-readable single-result rendering. Used by bench() callers that
    -- don't want to build a suite.
    return string.format(
        "%s\n  %.2f ns/op  (%.0f ops/sec)  rsd=%.2f%%  samples=%d  outliers=%d  alloc=%.4f kb/op",
        result.name, result.ns_per_op, result.ops_per_sec,
        result.rsd_pct, result.samples, result.outliers, result.allocs_kb_per_op or 0)
end

return M
