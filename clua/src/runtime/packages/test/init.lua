-- test -- describe/it test runner.
--
-- Public surface:
--   test.describe(name, fn)
--   test.it(name, fn, opts?)
--   test.before_each(fn) / after_each(fn)
--   test.before_all(fn)  / after_all(fn)
--   test.pending(name, why?)
--   test.run(opts?)            -> result table; also prints to stdout
--   test.set_reporter(name|fn)
--   test.reset()               -- drop all registered suites (for re-use in one process)
--
-- it() opts: { tags={"slow","io"}, timeout_ms=5000, only=true, skip=true }
--
-- run() opts:
--   reporter   "spec" | "tap" | "junit-xml" | "json" | function
--   filter     string pattern matched against "describe > it" path
--   tags       list of tag names; an it() runs only if it matches at least one
--   exclude_tags
--   parallel   "auto" | integer | false   -- uses pool package when available
--   bail       stop on first failure
--   seed       passed through to property-like consumers; not used here
--
-- Async: if an it() body returns a function, it is treated as an async test
-- and called with a `done(err?)` callback. The runner waits up to timeout_ms
-- using a simple busy-poll over `os.clock`.

local M = {}

-- ===== State ==========================================================

local _root = {
    kind = "describe",
    name = "",
    children = {},
    before_each = {},
    after_each  = {},
    before_all  = {},
    after_all   = {},
}
local _current = _root
local _has_only = false  -- set when any it() uses opts.only

function M.reset()
    _root = { kind = "describe", name = "", children = {},
              before_each = {}, after_each = {},
              before_all  = {}, after_all  = {} }
    _current  = _root
    _has_only = false
end

-- ===== Registration API ==============================================

function M.describe(name, fn)
    local node = {
        kind   = "describe",
        name   = name,
        parent = _current,
        children = {},
        before_each = {}, after_each = {},
        before_all  = {}, after_all  = {},
    }
    table.insert(_current.children, node)
    local prev = _current
    _current = node
    local ok, err = pcall(fn)
    _current = prev
    if not ok then
        -- record as a synthetic failing test so the user sees it in the report
        table.insert(node.children, {
            kind = "it", name = "<describe body errored>", fn = function() error(err) end,
            opts = {},
        })
    end
end

function M.it(name, fn, opts)
    opts = opts or {}
    if opts.only or opts.focus then opts.only = true; _has_only = true end
    table.insert(_current.children, {
        kind = "it",
        name = name,
        fn   = fn,
        opts = opts,
    })
end

-- xit / skip variants: register an it that always reports as skipped.
function M.xit(name, fn, opts)
    opts = opts or {}
    opts.skip = true
    opts.reason = opts.reason or "xit"
    M.it(name, fn or function() end, opts)
end

-- Mark the currently-running it() as skipped by raising a control error.
-- Caught by `run_one` below.
local SKIP_TAG = "__test_skip__"
function M.skip(reason)
    error({ [SKIP_TAG] = true, reason = reason or "skipped" }, 2)
end

-- tags(...) lets the user attach tags inside the it body OR inside a describe
-- body (applied to subsequent it() calls in that describe).
function M.tags(...)
    local n = select("#", ...)
    local t = {}
    for i = 1, n do t[i] = select(i, ...) end
    if _current and _current.kind == "describe" then
        _current._default_tags = _current._default_tags or {}
        for _, tag in ipairs(t) do
            _current._default_tags[#_current._default_tags + 1] = tag
        end
    end
    return t
end

-- focus(name?) -- mark a single it() (by name) as `only`, or focus the
-- describe currently being built when no name passed.
function M.focus(target)
    _has_only = true
    if type(target) == "string" then
        for _, c in ipairs(_current.children) do
            if c.kind == "it" and c.name == target then c.opts.only = true end
            if c.kind == "describe" and c.name == target then
                local function mark(node)
                    for _, ch in ipairs(node.children) do
                        if ch.kind == "it" then ch.opts.only = true
                        else mark(ch) end
                    end
                end
                mark(c)
            end
        end
    else
        -- Focus the surrounding describe -- mark every direct child it.
        for _, c in ipairs(_current.children) do
            if c.kind == "it" then c.opts.only = true end
        end
    end
end

function M.pending(name, why)
    table.insert(_current.children, {
        kind   = "it",
        name   = name,
        opts   = { skip = true, reason = why or "pending" },
        fn     = function() end,
    })
end

function M.before_each(fn) table.insert(_current.before_each, fn) end
function M.after_each(fn)  table.insert(_current.after_each,  fn) end
function M.before_all(fn)  table.insert(_current.before_all,  fn) end
function M.after_all(fn)   table.insert(_current.after_all,   fn) end

-- ===== Reporters =====================================================

local function ansi(code) return string.char(27) .. "[" .. code .. "m" end
local _C = {
    reset = ansi("0"), green = ansi("32"), red = ansi("31"),
    yellow = ansi("33"), gray = ansi("90"), bold = ansi("1"),
}

local Reporters = {}

Reporters.spec = {
    suite_start = function() io.write("\n") end,
    describe_enter = function(name, depth)
        io.write(string.rep("  ", depth) .. _C.bold .. name .. _C.reset .. "\n")
    end,
    describe_leave = function() end,
    it_result = function(rec, depth)
        local pad = string.rep("  ", depth + 1)
        if rec.status == "pass" then
            io.write(pad .. _C.green .. "[+]" .. _C.reset .. " " .. rec.name)
        elseif rec.status == "skip" then
            io.write(pad .. _C.yellow .. "[_]" .. _C.reset .. " " .. rec.name
                     .. _C.gray .. " (" .. (rec.reason or "skipped") .. ")" .. _C.reset)
        else
            io.write(pad .. _C.red .. "[-]" .. _C.reset .. " " .. rec.name)
        end
        io.write(_C.gray .. string.format("  %.1fms", rec.duration_ms) .. _C.reset .. "\n")
        if rec.status == "fail" then
            for line in tostring(rec.error):gmatch("[^\n]+") do
                io.write(pad .. "    " .. _C.red .. line .. _C.reset .. "\n")
            end
        end
    end,
    suite_end = function(summary)
        io.write("\n")
        io.write(string.format("[+] %d passed, [-] %d failed, [_] %d skipped  (%d total, %.1fms)\n",
            summary.passed, summary.failed, summary.skipped, summary.total, summary.duration_ms))
    end,
}

-- Minimal one-glyph-per-test reporter. Final line summarises.
Reporters.dot = {
    suite_start = function() io.write("\n") end,
    describe_enter = function() end,
    describe_leave = function() end,
    it_result = function(rec, _depth, _idx)
        if rec.status == "pass" then
            io.write(_C.green .. "." .. _C.reset)
        elseif rec.status == "skip" then
            io.write(_C.yellow .. "s" .. _C.reset)
        else
            io.write(_C.red .. "F" .. _C.reset)
        end
    end,
    suite_end = function(summary)
        io.write("\n\n")
        io.write(string.format(
            "[+] %d passed, [-] %d failed, [_] %d skipped  (%d total, %.1fms)\n",
            summary.passed, summary.failed, summary.skipped, summary.total, summary.duration_ms))
        if summary.failed > 0 then
            io.write("\nfailures:\n")
            for _, rec in ipairs(summary.records) do
                if rec.status == "fail" then
                    io.write("  - " .. (rec.path or rec.name) .. "\n")
                    for line in tostring(rec.error):gmatch("[^\n]+") do
                        io.write("      " .. _C.red .. line .. _C.reset .. "\n")
                    end
                end
            end
        end
    end,
}

-- Spec name alias.
Reporters.junit_xml = nil  -- set after junit-xml is declared

Reporters.tap = {
    suite_start = function(summary) io.write("TAP version 13\n") end,
    describe_enter = function() end,
    describe_leave = function() end,
    it_result = function(rec, _depth, idx)
        if rec.status == "pass" then
            io.write(string.format("ok %d - %s\n", idx, rec.path))
        elseif rec.status == "skip" then
            io.write(string.format("ok %d - %s # SKIP %s\n", idx, rec.path, rec.reason or ""))
        else
            io.write(string.format("not ok %d - %s\n", idx, rec.path))
            io.write("  ---\n")
            io.write("  message: " .. tostring(rec.error):gsub("\n", "\n    ") .. "\n")
            io.write("  ...\n")
        end
    end,
    suite_end = function(summary)
        io.write(string.format("1..%d\n", summary.total))
    end,
}

Reporters["junit_xml"] = nil  -- placeholder; populated by junit-xml below
Reporters["junit-xml"] = {
    suite_start = function() io.write('<?xml version="1.0" encoding="UTF-8"?>\n') end,
    describe_enter = function() end,
    describe_leave = function() end,
    -- We buffer it_result in the runner and flush from suite_end.
    it_result = function() end,
    suite_end = function(summary)
        io.write(string.format(
            '<testsuite name="lua" tests="%d" failures="%d" skipped="%d" time="%.3f">\n',
            summary.total, summary.failed, summary.skipped, summary.duration_ms / 1000))
        for _, rec in ipairs(summary.records) do
            io.write(string.format('  <testcase classname="%s" name="%s" time="%.3f"',
                rec.suite or "root", rec.name, rec.duration_ms / 1000))
            if rec.status == "pass" then
                io.write("/>\n")
            else
                io.write(">\n")
                if rec.status == "skip" then
                    io.write(string.format('    <skipped message="%s"/>\n', rec.reason or ""))
                else
                    -- XML-escape the error.
                    local esc = tostring(rec.error):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
                    io.write('    <failure>' .. esc .. '</failure>\n')
                end
                io.write("  </testcase>\n")
            end
        end
        io.write("</testsuite>\n")
    end,
}

-- Snake-case alias for the canonical hyphen name.
Reporters.junit_xml = Reporters["junit-xml"]

Reporters.json = {
    suite_start = function() end,
    describe_enter = function() end,
    describe_leave = function() end,
    it_result = function() end,
    suite_end = function(summary)
        -- Tiny in-place JSON serializer (avoid coupling to json package).
        local function enc(v)
            local t = type(v)
            if t == "nil" then return "null"
            elseif t == "boolean" then return tostring(v)
            elseif t == "number" then
                if v ~= v or v == math.huge or v == -math.huge then return "null" end
                return tostring(v)
            elseif t == "string" then
                local esc = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                                :gsub('\r', '\\r'):gsub('\t', '\\t')
                return '"' .. esc .. '"'
            elseif t == "table" then
                local n = #v
                if n > 0 then
                    local parts = {}
                    for i = 1, n do parts[i] = enc(v[i]) end
                    return "[" .. table.concat(parts, ",") .. "]"
                end
                local keys = {}
                for k in pairs(v) do keys[#keys + 1] = k end
                table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
                local parts = {}
                for _, k in ipairs(keys) do
                    parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(v[k])
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
            return "null"
        end
        io.write(enc({
            passed = summary.passed, failed = summary.failed,
            skipped = summary.skipped, total = summary.total,
            duration_ms = summary.duration_ms,
            tests = summary.records,
        }) .. "\n")
    end,
}

function M.set_reporter(name_or_fn)
    if type(name_or_fn) == "function" then
        Reporters._custom = name_or_fn(_C, io)
    elseif Reporters[name_or_fn] then
        Reporters._chosen = name_or_fn
    else
        error("test.set_reporter: unknown reporter " .. tostring(name_or_fn))
    end
end

-- ===== Test execution ================================================

local function now_ms()
    return os.clock() * 1000
end

-- Run all before/after hooks in lexical order along the ancestor chain.
local function collect_hooks(node, key, out)
    if node.parent then collect_hooks(node.parent, key, out) end
    for _, fn in ipairs(node[key]) do out[#out + 1] = fn end
    return out
end

local function run_hooks(hooks)
    for _, h in ipairs(hooks) do
        local ok, err = pcall(h)
        if not ok then return false, err end
    end
    return true
end

-- Execute a single `it`, honoring async + timeout.
local function run_one(it, parent)
    local rec = {
        kind = "it",
        name = it.name,
        opts = it.opts,
        path = it._path,
        suite = parent.name ~= "" and parent.name or nil,
    }
    if it.opts.skip then
        rec.status = "skip"
        rec.reason = it.opts.reason
        rec.duration_ms = 0
        return rec
    end

    local before = collect_hooks(parent, "before_each", {})
    local after  = collect_hooks(parent, "after_each", {})

    local start = now_ms()
    local ok, err = run_hooks(before)
    if not ok then
        rec.status = "fail"
        rec.error = "before_each failed: " .. tostring(err)
        rec.duration_ms = now_ms() - start
        return rec
    end

    -- Run body. If it returns a function, treat as async with a `done` callback.
    local body_ok, ret = pcall(it.fn)
    if body_ok and type(ret) == "function" then
        local timeout = it.opts.timeout_ms or 5000
        local done_called = false
        local done_err = nil
        local function done(e)
            done_called = true
            done_err = e
        end
        local sok, serr = pcall(ret, done)
        if not sok then
            body_ok, ret = false, serr
        else
            local deadline = now_ms() + timeout
            while not done_called and now_ms() < deadline do
                -- Busy spin; the user's runtime is expected to advance via
                -- coroutine yields or the async package's scheduler if loaded.
            end
            if not done_called then
                body_ok = false; ret = "async timeout after " .. timeout .. "ms"
            elseif done_err then
                body_ok = false; ret = done_err
            end
        end
    end

    local aok, aerr = run_hooks(after)
    rec.duration_ms = now_ms() - start
    -- Did the body raise a skip() sentinel?
    if not body_ok and type(ret) == "table" and ret[SKIP_TAG] then
        rec.status = "skip"
        rec.reason = ret.reason
    elseif not body_ok then
        rec.status = "fail"; rec.error = ret
    elseif not aok then
        rec.status = "fail"; rec.error = "after_each failed: " .. tostring(aerr)
    else
        rec.status = "pass"
    end
    return rec
end

-- Filter: tags + only + name pattern.
local function should_run(it, opts)
    if _has_only and not it.opts.only then return false end
    if opts.filter and not string.find(it._path, opts.filter) then return false end
    if opts.tags and #opts.tags > 0 then
        local hit = false
        for _, t in ipairs(opts.tags) do
            for _, tag in ipairs(it.opts.tags or {}) do
                if t == tag then hit = true; break end
            end
            if hit then break end
        end
        if not hit then return false end
    end
    if opts.exclude_tags and #opts.exclude_tags > 0 then
        for _, t in ipairs(opts.exclude_tags) do
            for _, tag in ipairs(it.opts.tags or {}) do
                if t == tag then return false end
            end
        end
    end
    return true
end

-- Collect default tags inherited from the chain of describe ancestors.
local function inherited_tags(node)
    local out = {}
    local n = node
    while n do
        if n._default_tags then
            for _, t in ipairs(n._default_tags) do out[#out + 1] = t end
        end
        n = n.parent
    end
    return out
end

-- DFS to assign path strings and collect runnable its.
local function walk(node, prefix, all)
    for _, c in ipairs(node.children) do
        if c.kind == "describe" then
            walk(c, (prefix == "" and c.name) or (prefix .. " > " .. c.name), all)
        else
            c._path = (prefix == "" and c.name) or (prefix .. " > " .. c.name)
            c._parent = node
            -- Merge inherited describe-level tags into this it's tag list.
            local inh = inherited_tags(node)
            if #inh > 0 then
                local merged = {}
                for _, t in ipairs(c.opts.tags or {}) do merged[#merged + 1] = t end
                for _, t in ipairs(inh)                 do merged[#merged + 1] = t end
                c.opts.tags = merged
            end
            all[#all + 1] = c
        end
    end
end

-- Best-effort parallel runner via the `pool` package if present.
local function try_pool(opts)
    if opts.parallel == false or opts.parallel == nil then return nil end
    local ok, pool = pcall(require, "pool")
    if not ok then return nil end
    return pool
end

function M.run(opts)
    opts = opts or {}
    local reporter
    if Reporters._custom then reporter = Reporters._custom
    else reporter = Reporters[opts.reporter or Reporters._chosen or "spec"] end
    if not reporter then error("test.run: unknown reporter " .. tostring(opts.reporter)) end

    local all = {}
    walk(_root, "", all)

    -- Random shuffle (Fisher-Yates) when a random_seed is provided.
    if opts.random_seed or opts.random then
        local seed = opts.random_seed or os.time()
        local state = seed & 0xFFFFFFFFFFFFFFFF
        if state == 0 then state = 1 end
        local function nxt()
            state = state ~ (state << 13); state = state & 0xFFFFFFFFFFFFFFFF
            state = state ~ (state >> 7)
            state = state ~ (state << 17); state = state & 0xFFFFFFFFFFFFFFFF
            return state
        end
        for i = #all, 2, -1 do
            local j = 1 + (nxt() % i)
            all[i], all[j] = all[j], all[i]
        end
    end

    -- Run before_all hooks of each describe ancestor once on first child.
    local started = {}
    local function maybe_before_all(node)
        if node.parent then maybe_before_all(node.parent) end
        if not started[node] then
            started[node] = true
            for _, fn in ipairs(node.before_all) do
                local ok, err = pcall(fn)
                if not ok then
                    error("before_all failed in '" .. node.name .. "': " .. tostring(err), 0)
                end
            end
        end
    end

    local records = {}
    local summary = { passed = 0, failed = 0, skipped = 0, total = 0, duration_ms = 0,
                      records = records }

    reporter.suite_start(summary)

    local suite_start = now_ms()

    -- Group its by describe so we can emit describe_enter once.
    local last_path = nil
    local function emit_describe_for(it)
        if reporter.describe_enter then
            -- Walk parents top-down, emit any not yet announced.
            local chain = {}
            local n = it._parent
            while n and n ~= _root do
                table.insert(chain, 1, n); n = n.parent
            end
            for depth, node in ipairs(chain) do
                if not node._announced then
                    reporter.describe_enter(node.name, depth - 1)
                    node._announced = true
                end
            end
        end
    end

    local pool = try_pool(opts)
    -- We currently run sequentially even if `pool` is present; the harness
    -- doesn't try to share suite-level mutable hook state across workers.
    -- (Async tests above use a cooperative deadline -- the CLua runtime
    -- expects callers to advance coroutines from outside.)
    local _ = pool  -- reserved; not yet wired in

    for idx, it in ipairs(all) do
        if should_run(it, opts) then
            maybe_before_all(it._parent)
            emit_describe_for(it)

            local rec = run_one(it, it._parent)
            records[#records + 1] = rec
            summary.total = summary.total + 1
            if rec.status == "pass" then summary.passed = summary.passed + 1
            elseif rec.status == "skip" then summary.skipped = summary.skipped + 1
            else summary.failed = summary.failed + 1 end

            local depth = 0
            local n = it._parent
            while n and n ~= _root do depth = depth + 1; n = n.parent end
            reporter.it_result(rec, depth, idx)

            if opts.bail and rec.status == "fail" then break end
        end
    end

    -- Run after_all for any describe that had before_all.
    for node in pairs(started) do
        for _, fn in ipairs(node.after_all) do pcall(fn) end
    end

    summary.duration_ms = now_ms() - suite_start
    reporter.suite_end(summary)

    -- Reset _announced flags so a subsequent run isn't silent.
    local function clear(node)
        node._announced = nil
        for _, c in ipairs(node.children) do
            if c.kind == "describe" then clear(c) end
        end
    end
    clear(_root)

    return summary
end

-- ===== Callable module: `test "name" (function() ... end)` ============
--
-- Lets the user write:
--     test "math" (function()
--         it("adds", function() ... end)
--     end)
-- The string call returns a function that, when invoked with the body,
-- registers a top-level describe.

return setmetatable(M, {
    __call = function(self, name, fn)
        if type(name) == "function" then
            -- test(function() ... end) -- anonymous group at root level
            return self.describe("", name)
        end
        if type(fn) == "function" then
            return self.describe(name, fn)
        end
        -- test "name" form returns a closure expecting the body.
        return function(body) return self.describe(name, body) end
    end,
})
