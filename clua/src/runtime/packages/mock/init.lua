-- mock -- function spies, stubs, fakes.
--
-- Public surface:
--   mock.spy(fn?)           record every call; optionally invoke fn underneath
--   mock.stub(fn)           spy that swallows the impl; chain :returns / :throws / :when
--   mock.fake(impl)         spy that uses `impl` as the body
--   mock.replace(module, name, replacement)  -> restorer fn
--   mock.mock(opts?)        object whose any-key returns auto-spies
--   mock.verify_calls(spy, expected_calls)   matcher-based call validation
--
-- A spy object provides:
--   spy(...)                 invoke (records call, returns spy result)
--   spy:calls()              list of {args=, returns=, threw=} records
--   spy:call_count()
--   spy:called_with(args...) true if any call's args match
--   spy:returns(...)         queue a return value (stub-style)
--   spy:throws(err)          next call throws this error
--   spy:when(args...).returns(...) / .throws(err)  matcher-keyed return
--   spy:reset()              clear recorded calls + queued returns
--
-- Matcher semantics: every arg in :when() / :called_with() / verify_calls is
-- either a literal (deep-compared) or a function (predicate). A sentinel
-- `mock.any` matches anything.

local M = {}

-- ===== Helpers ========================================================

local function deep_eq(a, b)
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return false end
    if ta ~= "table" then
        if ta == "number" and a ~= a and b ~= b then return true end
        return false
    end
    for k, va in pairs(a) do
        if not deep_eq(va, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Match a single arg against a matcher (literal | predicate | mock.any).
local function arg_match(actual, matcher)
    if matcher == M.any then return true end
    if type(matcher) == "function" then return matcher(actual) == true end
    return deep_eq(actual, matcher)
end

local function args_match(actual_args, matchers)
    if #matchers ~= actual_args.n then return false end
    for i = 1, matchers.n do
        if not arg_match(actual_args[i], matchers[i]) then return false end
    end
    return true
end

-- Sentinel: matches any single argument.
M.any = setmetatable({}, { __tostring = function() return "<mock.any>" end })

-- ===== match.* matchers ================================================
--
-- Predicate matchers can be passed anywhere `:when(...)`, `:was_called_with(...)`,
-- or `verify_calls` accepts a matcher.

M.match = {
    any        = M.any,
    is_number  = function(v) return type(v) == "number" end,
    is_string  = function(v) return type(v) == "string" end,
    is_bool    = function(v) return type(v) == "boolean" end,
    is_table   = function(v) return type(v) == "table" end,
    is_fn      = function(v) return type(v) == "function" end,
    is_nil     = function(v) return v == nil end,
    is_truthy  = function(v) return v and true or false end,
    is_falsy   = function(v) return not v end,
}

function M.match.matches(pattern)
    return function(v)
        return type(v) == "string" and string.match(v, pattern) ~= nil
    end
end

function M.match.contains(needle)
    return function(v)
        if type(v) == "string" then
            return type(needle) == "string" and string.find(v, needle, 1, true) ~= nil
        end
        if type(v) == "table" then
            for _, item in pairs(v) do
                if deep_eq(item, needle) then return true end
            end
        end
        return false
    end
end

function M.match.equals(expected)
    return function(v) return deep_eq(v, expected) end
end

function M.match.gt(n) return function(v) return type(v) == "number" and v >  n end end
function M.match.ge(n) return function(v) return type(v) == "number" and v >= n end end
function M.match.lt(n) return function(v) return type(v) == "number" and v <  n end end
function M.match.le(n) return function(v) return type(v) == "number" and v <= n end end
function M.match.between(lo, hi)
    return function(v) return type(v) == "number" and v >= lo and v <= hi end
end

-- Pack varargs preserving nil holes. Avoid the `{ n=..., ... }` mixed
-- constructor pattern -- the CLua JIT cannot codegen it. Build manually.
local function pack(...)
    local n = select("#", ...)
    local t = { n = n }
    for i = 1, n do t[i] = select(i, ...) end
    return t
end

-- ===== Spy / stub object =============================================

local Spy = {}
Spy.__index = Spy

local function new_spy(impl)
    local s = {
        _impl     = impl,
        _calls    = {},
        _returns  = {},        -- FIFO queue of {kind="return", values={...}} | {kind="throw", err=}
        _matched  = {},        -- list of {match_args, action}
        _any_call = nil,       -- default action when nothing matches
    }
    setmetatable(s, Spy)
    -- Allow `spy(...)` invocation.
    return setmetatable({}, {
        __index = function(_, k) return s[k] or Spy[k] end,
        __newindex = function(_, k, v) s[k] = v end,
        __call = function(_, ...) return Spy._invoke(s, ...) end,
    }), s
end

-- Public constructor returns the callable shell.
function M.spy(fn)
    local shell = new_spy(fn)
    return shell
end

function M.stub(value)
    -- A stub is a spy with no recorded impl. If `value` is a function, it's
    -- treated as the default impl (same as fake). Any other value becomes a
    -- default return value -- shorthand for `mock.stub():returns(value)`.
    if type(value) == "function" then
        return new_spy(value)
    end
    local shell = new_spy(nil)
    if value ~= nil then
        -- Install a default return value (non-consuming -- always returned).
        shell._impl = function() return value end
    end
    return shell
end

function M.fake(impl)
    return new_spy(impl)
end

-- Internal core dispatch.
function Spy:_invoke(...)
    local args = pack(...)
    -- Find matched action.
    local action
    for _, m in ipairs(self._matched) do
        if args_match(args, m.matchers) then action = m.action; break end
    end
    -- Then queued returns (FIFO).
    if not action and #self._returns > 0 then
        action = table.remove(self._returns, 1)
    end
    -- Then fall back to default impl, or `_any_call`.
    local rec = { args = args }
    local results
    if action then
        if action.kind == "throw" then
            rec.threw = action.err
            table.insert(self._calls, rec)
            error(action.err, 2)
        elseif action.kind == "return" then
            results = action.values
        elseif action.kind == "fn" then
            results = pack(action.fn(table.unpack(args, 1, args.n)))
        end
    elseif self._impl then
        results = pack(self._impl(table.unpack(args, 1, args.n)))
    else
        results = { n = 0 }
    end
    rec.returns = results
    table.insert(self._calls, rec)
    return table.unpack(results, 1, results.n)
end

-- Spy queries.
function Spy:calls()
    -- Return shallow copies so the caller cannot mutate the recorded log.
    local out = {}
    for i, c in ipairs(self._calls) do
        out[i] = {
            args    = { table.unpack(c.args, 1, c.args.n) },
            returns = c.returns and { table.unpack(c.returns, 1, c.returns.n) } or nil,
            threw   = c.threw,
        }
        out[i].args.n    = c.args.n
        if c.returns then out[i].returns.n = c.returns.n end
    end
    return out
end

function Spy:call_count()
    return #self._calls
end

function Spy:called_with(...)
    local matchers = pack(...)
    for _, c in ipairs(self._calls) do
        if args_match(c.args, matchers) then return true end
    end
    return false
end

-- Spec-name aliases.
function Spy:was_called(n)
    if n == nil then return #self._calls > 0 end
    return #self._calls == n
end

function Spy:was_called_with(...) return Spy.called_with(self, ...) end

-- `:returns_for({arg1, arg2}, ...)` - matcher-keyed return shortcut.
function Spy:returns_for(args, ...)
    local matchers
    if type(args) == "table" and args.n then
        matchers = args
    elseif type(args) == "table" then
        matchers = { n = #args }
        for i = 1, #args do matchers[i] = args[i] end
    else
        matchers = pack(args)
    end
    table.insert(self._matched, {
        matchers = matchers,
        action   = { kind = "return", values = pack(...) },
    })
    return self
end

-- Aliases requested by the public spec.
Spy.call_history = Spy.calls

-- Queue a return value to consume on next call (FIFO).
function Spy:returns(...)
    table.insert(self._returns, { kind = "return", values = pack(...) })
    return self
end

function Spy:throws(err)
    table.insert(self._returns, { kind = "throw", err = err })
    return self
end

-- `:when(matchers).returns(...)` / `.throws(err)`.
function Spy:when(...)
    local matchers = pack(...)
    local spy_self = self
    return {
        returns = function(...)
            table.insert(spy_self._matched, {
                matchers = matchers,
                action   = { kind = "return", values = pack(...) },
            })
            return spy_self
        end,
        throws = function(err)
            table.insert(spy_self._matched, {
                matchers = matchers,
                action   = { kind = "throw", err = err },
            })
            return spy_self
        end,
        invokes = function(fn)
            -- Run a user fn for matched args.
            table.insert(spy_self._matched, {
                matchers = matchers,
                action   = { kind = "fn", fn = fn },
            })
            return spy_self
        end,
    }
end

function Spy:reset()
    self._calls   = {}
    self._returns = {}
    self._matched = {}
    return self
end

-- ===== module replace + auto-mock object ==============================

-- Patch `module[name]` to `replacement` and return a restorer.
function M.replace(module, name, replacement)
    if type(module) ~= "table" then
        error("mock.replace: module must be a table")
    end
    local original = module[name]
    module[name] = replacement
    -- Return a one-shot restorer; calling it twice is a no-op.
    local restored = false
    return function()
        if restored then return end
        module[name] = original
        restored = true
    end
end

-- mock.mock() returns a table where every key access lazily creates a spy.
-- Useful when stubbing out a whole module surface.
function M.mock(opts)
    opts = opts or {}
    local store = {}
    return setmetatable({}, {
        __index = function(_, k)
            if store[k] == nil then
                store[k] = M.spy(opts.default)
            end
            return store[k]
        end,
        __newindex = function(_, k, v) store[k] = v end,
        __pairs = function() return pairs(store) end,
    })
end

-- ===== verify_calls matcher ==========================================
--
-- expected_calls: list of arg-lists. Each entry is a table of matchers,
-- compared in order to recorded calls. Returns ok, why (string on failure).

function M.verify_calls(spy, expected_calls)
    local actual = spy:calls()
    if #actual ~= #expected_calls then
        return false, string.format("expected %d calls, got %d", #expected_calls, #actual)
    end
    for i, expected in ipairs(expected_calls) do
        local act = actual[i]
        local matchers = expected
        matchers.n = matchers.n or #expected
        local got = pack(table.unpack(act.args, 1, act.args.n))
        if not args_match(got, matchers) then
            return false, string.format("call %d arg mismatch", i)
        end
    end
    return true
end

-- ===== mock.partial ===================================================
--
-- Replace a subset of keys on `t` with the given overrides. The returned
-- restorer puts the original values back. `overrides` keys may be values
-- (treated as direct replacements) or functions (treated as fakes).

function M.partial(t, overrides)
    if type(t) ~= "table" then error("mock.partial: t must be a table") end
    if type(overrides) ~= "table" then error("mock.partial: overrides must be a table") end
    local saved = {}
    for k, v in pairs(overrides) do
        saved[k] = t[k]
        t[k] = v
    end
    local restored = false
    return function()
        if restored then return end
        for k, v in pairs(saved) do t[k] = v end
        restored = true
    end
end

-- ===== mock.with (RAII-ish scoped patch) ==============================
--
-- with({patches...}, body_fn) installs patches, runs body, restores -- even
-- on error. patches is a list of { module, key, replacement } triples or a
-- map { [module] = { key=replacement, ... } }.

function M.with(patches, body)
    local restorers = {}
    -- Accept both layouts.
    if patches[1] and type(patches[1]) == "table" and patches[1][1] ~= nil then
        for _, p in ipairs(patches) do
            local module, key, replacement = p[1], p[2], p[3]
            restorers[#restorers + 1] = M.replace(module, key, replacement)
        end
    else
        for module, kvs in pairs(patches) do
            for k, v in pairs(kvs) do
                restorers[#restorers + 1] = M.replace(module, k, v)
            end
        end
    end
    local ok, err = pcall(body)
    for i = #restorers, 1, -1 do restorers[i]() end
    if not ok then error(err, 2) end
    return true
end

-- ===== mock.verify (assertion DSL) ====================================
--
-- verify(spy) returns an object with chainable assertions that raise on
-- mismatch -- the testing companion to verify_calls().
--
--   verify(spy):was_called()
--   verify(spy):was_called(3)
--   verify(spy):was_called_with("foo", mock.any)
--   verify(spy):was_not_called()
--   verify(spy):was_called_at_least(2)
--   verify(spy):was_called_at_most(5)

function M.verify(spy)
    local v = {}
    function v:was_called(n)
        if n == nil then
            if #spy._calls == 0 then
                error("verify: expected spy to have been called, got 0 calls", 2)
            end
        else
            if #spy._calls ~= n then
                error(string.format(
                    "verify: expected %d call(s), got %d", n, #spy._calls), 2)
            end
        end
        return v
    end
    function v:was_not_called()
        if #spy._calls > 0 then
            error(string.format(
                "verify: expected zero calls, got %d", #spy._calls), 2)
        end
        return v
    end
    function v:was_called_at_least(n)
        if #spy._calls < n then
            error(string.format(
                "verify: expected >= %d calls, got %d", n, #spy._calls), 2)
        end
        return v
    end
    function v:was_called_at_most(n)
        if #spy._calls > n then
            error(string.format(
                "verify: expected <= %d calls, got %d", n, #spy._calls), 2)
        end
        return v
    end
    function v:was_called_with(...)
        local matchers = pack(...)
        for _, c in ipairs(spy._calls) do
            if args_match(c.args, matchers) then return v end
        end
        local seen = {}
        for i, c in ipairs(spy._calls) do
            local parts = {}
            for j = 1, c.args.n do parts[j] = tostring(c.args[j]) end
            seen[i] = "(" .. table.concat(parts, ", ") .. ")"
        end
        error("verify: spy was not called with the given arguments; seen calls: "
              .. table.concat(seen, "; "), 2)
    end
    return v
end

return M
