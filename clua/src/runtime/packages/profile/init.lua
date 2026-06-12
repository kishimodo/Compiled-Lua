-- profile -- sampling profiler for Lua via debug.sethook.
--
-- Public surface:
--   profile.start(opts?)              -> nil   (opts: {rate_hz=100, mode="cpu"|"wall"})
--   profile.stop()                    -> profile data
--   profile.with(fn, opts?)           -> result, profile
--   profile.format(data, kind?)       -> string  (kind: "tree"|"flame"|"chrome_trace"|"pprof")
--
-- Implementation:
--   The Lua debug library exposes "count" hooks that fire every N VM
--   instructions. We use this to drive the sampler. "wall" and "cpu" both
--   end up using the same hook source -- in pure Lua we can't distinguish
--   blocked-on-syscall vs running -- so we tag the mode for downstream
--   awareness and adjust the count interval to approximate the requested Hz.
--
-- Sample shape:
--   { ts = os.clock_value, stack = { "file:line:func", ... } }   (leaf first)
--
-- Profile data shape:
--   { mode=, rate_hz=, started=, stopped=, samples = { ... }, total_samples = N }

local M = {}

-- ===== Stack capture ====================================================

local function stack_at(skip)
    -- Walk debug.getinfo upward; cap depth so a recursive monster can't
    -- blow our memory. 256 frames is way past any reasonable Lua call.
    local frames = {}
    local i = skip
    while i <= skip + 256 do
        local info = debug.getinfo(i, "Sln")
        if not info then break end
        if info.what ~= "C" then
            local src = info.short_src or info.source or "?"
            local line = info.currentline or 0
            local fn = info.name or info.namewhat or "?"
            if fn == "" then fn = "anon" end
            frames[#frames + 1] = string.format("%s:%d:%s", src, line, fn)
        end
        i = i + 1
    end
    return frames
end

-- ===== Active session state ============================================

local _active = nil

-- Tuning the count interval is heuristic. Lua doesn't tell us "instructions
-- per second" so we calibrate at start by running a tight loop and counting
-- iterations per second. The interval is rate_hz / instructions_per_second.
local function calibrate_count(target_hz)
    local t0 = os.clock()
    local n = 0
    while os.clock() - t0 < 0.05 do
        n = n + 1
    end
    -- n iterations took ~50ms. instructions/sec = n / 0.05 (rough).
    local ips = n / 0.05
    -- We want hook to fire ~target_hz times/sec, so count = ips / target_hz.
    local cnt = math.max(1, math.floor(ips / target_hz))
    return cnt
end

function M.start(opts)
    if _active then error("profile.start: already profiling") end
    opts = opts or {}
    local rate = opts.rate_hz or 100
    local mode = opts.mode or "cpu"
    local count = opts.count or calibrate_count(rate)

    _active = {
        mode          = mode,
        rate_hz       = rate,
        count         = count,
        started       = os.clock(),
        stopped       = nil,
        samples       = {},
        total_samples = 0,
    }

    -- The hook captures the user's stack at this moment. We skip 2 frames
    -- (the hook itself + this captured closure) so the leaf is the user's
    -- code, not our profiler internals.
    local function hook()
        local s = _active
        if not s then return end
        s.total_samples = s.total_samples + 1
        s.samples[#s.samples + 1] = { ts = os.clock(), stack = stack_at(3) }
    end

    debug.sethook(hook, "", count)
end

function M.stop()
    if not _active then error("profile.stop: not profiling") end
    debug.sethook()
    _active.stopped = os.clock()
    local out = _active
    _active = nil
    return out
end

function M.with(fn, opts)
    M.start(opts)
    local ok, result = pcall(fn)
    local data = M.stop()
    if not ok then error(result, 2) end
    return result, data
end

-- ===== Aggregation ======================================================
--
-- A "tree" rolls samples into a call-tree keyed by frame. Each node:
--   { name=, self=count_with_this_as_leaf, total=count_anywhere_in_stack,
--     children={name=node, ...} }

local function aggregate_tree(samples)
    local root = { name = "<root>", self = 0, total = 0, children = {} }
    for i = 1, #samples do
        local stack = samples[i].stack
        -- Walk root-to-leaf so the tree fans out from the entry point.
        local node = root
        node.total = node.total + 1
        for j = #stack, 1, -1 do
            local frame = stack[j]
            local child = node.children[frame]
            if not child then
                child = { name = frame, self = 0, total = 0, children = {} }
                node.children[frame] = child
            end
            child.total = child.total + 1
            node = child
        end
        node.self = node.self + 1
    end
    return root
end

-- ===== Formatters =======================================================

local function format_tree(root, depth, total_samples, out)
    -- Walk depth-first, sorted by total samples descending so the hottest
    -- branches sit at the top.
    local children = {}
    for _, c in pairs(root.children) do children[#children + 1] = c end
    table.sort(children, function(a, b) return a.total > b.total end)
    for _, c in ipairs(children) do
        local pct = total_samples > 0 and (c.total / total_samples) * 100 or 0
        local indent = string.rep("  ", depth)
        out[#out + 1] = string.format("%s%-40s %6d (%5.1f%%) self=%d",
            indent, c.name, c.total, pct, c.self)
        format_tree(c, depth + 1, total_samples, out)
    end
end

local function format_flame(samples)
    -- Brendan Gregg's collapsed-stack format:
    --   frame_root;frame_mid;frame_leaf <count>
    -- One folded entry per unique stack signature.
    local counts = {}
    for i = 1, #samples do
        local stack = samples[i].stack
        local rev = {}
        for j = #stack, 1, -1 do rev[#rev + 1] = stack[j] end
        local key = table.concat(rev, ";")
        counts[key] = (counts[key] or 0) + 1
    end
    local lines = {}
    for k, v in pairs(counts) do lines[#lines + 1] = k .. " " .. v end
    table.sort(lines)
    return table.concat(lines, "\n")
end

local function format_chrome_trace(data)
    -- Chrome's Trace Event Format (chrome://tracing). We emit "X" complete
    -- events: each sample becomes a 0-duration event whose stack appears
    -- as a series of nested events via fake "B"/"E" pairs.
    --
    -- The simpler path used here: emit one "i" instant event per sample
    -- carrying the leaf stack frame, with sf-style stackFrames table.
    local json = (function() local ok, m = pcall(require, "json"); return ok and m or nil end)()
    if not json then
        error("profile.format(chrome_trace): requires the json package")
    end
    local events = {}
    local pid = 1
    local tid = 1
    for i = 1, #data.samples do
        local s = data.samples[i]
        events[#events + 1] = {
            name = s.stack[1] or "?",
            ph   = "i",       -- instantaneous
            ts   = math.floor((s.ts - data.started) * 1e6),
            pid  = pid,
            tid  = tid,
            s    = "t",       -- thread-scoped
            args = { stack = s.stack },
        }
    end
    return json.encode({ traceEvents = events, displayTimeUnit = "ms" })
end

-- pprof is a protobuf format. A full implementation is out of scope, so we
-- emit an "approximate pprof": the same logical content as a folded flame
-- graph but framed in pprof's JSON-ish summary used by some tooling. This
-- is documented as approximate via the contract -- callers should use
-- "flame" or "chrome_trace" for real flame charts.
local function format_pprof(data)
    local json = (function() local ok, m = pcall(require, "json"); return ok and m or nil end)()
    if not json then
        error("profile.format(pprof): requires the json package")
    end
    -- Build the string table + location table per the pprof model.
    local strings, str_idx = { "" }, { [""] = 0 }
    local function intern(s)
        if str_idx[s] then return str_idx[s] end
        strings[#strings + 1] = s
        str_idx[s] = #strings - 1
        return str_idx[s]
    end
    local functions, fn_idx = {}, {}
    local locations, loc_idx = {}, {}
    local function loc_for(frame)
        if loc_idx[frame] then return loc_idx[frame] end
        local file, line, fn = frame:match("^(.-):(%d+):(.*)$")
        line = tonumber(line) or 0
        local fkey = (fn or "?") .. "|" .. (file or "?")
        local fid = fn_idx[fkey]
        if not fid then
            functions[#functions + 1] = {
                id = #functions + 1,
                name = intern(fn or "?"),
                filename = intern(file or "?"),
            }
            fn_idx[fkey] = #functions
            fid = #functions
        end
        locations[#locations + 1] = {
            id = #locations + 1,
            line = { { functionId = fid, line = line } },
        }
        loc_idx[frame] = #locations
        return #locations
    end
    local samples = {}
    for i = 1, #data.samples do
        local stack = data.samples[i].stack
        local locs = {}
        for j = 1, #stack do locs[j] = loc_for(stack[j]) end
        samples[i] = { locationId = locs, value = { 1 } }
    end
    return json.encode({
        sampleType = { { type = intern("samples"), unit = intern("count") } },
        sample     = samples,
        location   = locations,
        ["function"] = functions,
        stringTable = strings,
        durationNanos = math.floor(((data.stopped or os.clock()) - data.started) * 1e9),
        periodType = { type = intern(data.mode), unit = intern("hz") },
        period     = data.rate_hz,
        _note      = "approximate pprof: encoded as JSON, not protobuf",
    })
end

function M.format(data, kind)
    kind = kind or "tree"
    if kind == "tree" then
        local tree = aggregate_tree(data.samples)
        local out = { string.format("profile: %d samples, %.3fs",
            data.total_samples, (data.stopped or os.clock()) - data.started) }
        format_tree(tree, 0, data.total_samples, out)
        return table.concat(out, "\n")
    elseif kind == "flame" then
        return format_flame(data.samples)
    elseif kind == "chrome_trace" then
        return format_chrome_trace(data)
    elseif kind == "pprof" then
        return format_pprof(data)
    else
        error("profile.format: unknown kind " .. tostring(kind))
    end
end

-- ===== Diagnostics ======================================================

function M.is_active() return _active ~= nil end

return M
