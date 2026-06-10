-- assert_ex -- rich assertions.
--
-- Named "assert_ex" so it does not clobber Lua's built-in `assert`. Provides a
-- procedural form (`assert_ex.equal(a, b)`) and a fluent form
-- (`expect(v).to.equal(x).and_to.be.a("string")`).
--
-- Public surface:
--   assert_ex.equal(a, b, msg?)         deep equal for tables
--   assert_ex.not_equal(a, b, msg?)
--   assert_ex.near(a, b, eps, msg?)
--   assert_ex.truthy(v, msg?)
--   assert_ex.falsy(v, msg?)
--   assert_ex.is_nil(v, msg?)
--   assert_ex.is_type(v, type_name, msg?)
--   assert_ex.contains(t, v, msg?)
--   assert_ex.matches(s, pattern, msg?)
--   assert_ex.throws(fn, expected_pat?, msg?)
--   assert_ex.not_throws(fn, msg?)
--   assert_ex.has_key(t, k, msg?)
--   assert_ex.length(t, n, msg?)
--   assert_ex.same_shape(a, b, msg?)   structural equivalence ignoring values
--   assert_ex.keys(t, expected_keys, msg?)
--   assert_ex.expect(v) -> fluent chain
--
-- Failure raises with a `error(msg, 2)` so the call site is the failure point.
-- A failed deep-equal includes a diff fragment so the user sees what differs.

local M = {}

-- ===== Pretty-print for diffs ==========================================

local function pp(v, depth, seen)
    depth = depth or 0
    seen  = seen or {}
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "table" then
        if seen[v] then return "<cycle>" end
        seen[v] = true
        if depth > 4 then return "{...}" end
        local parts, np = {}, 0
        -- emit array part first for stable output
        local n = #v
        for i = 1, n do
            np = np + 1; parts[np] = pp(v[i], depth + 1, seen)
        end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                keys[#keys + 1] = k
            end
        end
        -- sort string keys for deterministic diff
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            np = np + 1
            parts[np] = string.format("[%s]=%s", pp(k, depth + 1, seen), pp(v[k], depth + 1, seen))
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ", ") .. "}"
    else
        return "<" .. t .. ">"
    end
end

M.pp = pp

-- ===== Deep equal with diff ============================================

-- Returns ok, first_diff_path (string), expected_summary, actual_summary.
local function deep_eq(a, b, path)
    path = path or "$"
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= tb then
        return false, path, pp(a), pp(b)
    end
    if ta ~= "table" then
        -- handle NaN: NaN ~= NaN by Lua spec; treat as equal only if both are NaN
        if ta == "number" and a ~= a and b ~= b then return true end
        return false, path, pp(a), pp(b)
    end
    -- both tables; walk keys present in either
    local seen = {}
    for k, va in pairs(a) do
        seen[k] = true
        local ok, p, e, ac = deep_eq(va, b[k], path .. "." .. tostring(k))
        if not ok then return false, p, e, ac end
    end
    for k, vb in pairs(b) do
        if not seen[k] then
            local p = path .. "." .. tostring(k)
            return false, p, "<absent>", pp(vb)
        end
    end
    return true
end

M.deep_eq = deep_eq

-- Build the error message + frame skip for a failed assertion.
local function fail(msg, ctx)
    if ctx then msg = msg .. "\n" .. ctx end
    error(msg, 3)
end

-- ===== Procedural assertions ===========================================

function M.equal(a, b, msg)
    local ok, path, exp, act = deep_eq(a, b)
    if ok then return true end
    local diff = string.format("  at %s\n  expected: %s\n  actual:   %s", path, exp, act)
    fail(msg or "values are not equal", diff)
end

function M.not_equal(a, b, msg)
    if deep_eq(a, b) then
        fail(msg or "values should differ", "  both: " .. pp(a))
    end
    return true
end

function M.near(a, b, eps, msg)
    if type(a) ~= "number" or type(b) ~= "number" then
        fail(msg or "near: requires numbers", "  got " .. type(a) .. " and " .. type(b))
    end
    eps = eps or 1e-9
    if math.abs(a - b) > eps then
        fail(msg or "values are not close",
             string.format("  |%g - %g| = %g > %g", a, b, math.abs(a - b), eps))
    end
    return true
end

function M.truthy(v, msg)
    if not v then fail(msg or "expected truthy", "  got: " .. pp(v)) end
    return true
end

function M.falsy(v, msg)
    if v then fail(msg or "expected falsy", "  got: " .. pp(v)) end
    return true
end

function M.is_nil(v, msg)
    if v ~= nil then fail(msg or "expected nil", "  got: " .. pp(v)) end
    return true
end

function M.is_type(v, type_name, msg)
    if type(v) ~= type_name then
        fail(msg or ("expected " .. type_name),
             "  got " .. type(v) .. ": " .. pp(v))
    end
    return true
end

function M.contains(t, v, msg)
    if type(t) == "string" then
        if not string.find(t, v, 1, true) then
            fail(msg or "string does not contain substring",
                 "  haystack: " .. pp(t) .. "\n  needle:   " .. pp(v))
        end
        return true
    end
    if type(t) ~= "table" then
        fail(msg or "contains: expected table or string", "  got " .. type(t))
    end
    for _, item in pairs(t) do
        if deep_eq(item, v) then return true end
    end
    fail(msg or "table does not contain value", "  needle: " .. pp(v))
end

function M.matches(s, pattern, msg)
    if type(s) ~= "string" then
        fail(msg or "matches: expected string", "  got " .. type(s))
    end
    if not string.match(s, pattern) then
        fail(msg or "pattern did not match",
             "  string:  " .. pp(s) .. "\n  pattern: " .. pp(pattern))
    end
    return true
end

function M.throws(fn, expected_pat, msg)
    local ok, err = pcall(fn)
    if ok then
        fail(msg or "expected function to throw", "  but it returned normally")
    end
    if expected_pat then
        local es = tostring(err)
        if not string.match(es, expected_pat) then
            fail(msg or "error did not match pattern",
                 "  pattern: " .. pp(expected_pat) .. "\n  error:   " .. pp(es))
        end
    end
    return err
end

function M.not_throws(fn, msg)
    local ok, err = pcall(fn)
    if not ok then
        fail(msg or "function threw unexpectedly", "  error: " .. tostring(err))
    end
    return true
end

function M.has_key(t, k, msg)
    if type(t) ~= "table" then
        fail(msg or "has_key: expected table", "  got " .. type(t))
    end
    if t[k] == nil then
        fail(msg or "table missing key", "  key: " .. pp(k))
    end
    return true
end

function M.length(t, n, msg)
    local got
    if type(t) == "string" then got = #t
    elseif type(t) == "table" then got = #t
    else fail(msg or "length: expected table or string", "  got " .. type(t)) end
    if got ~= n then
        fail(msg or "length mismatch",
             string.format("  expected: %d\n  actual:   %d", n, got))
    end
    return true
end

-- Structural equivalence: same key paths, but values may differ in content.
-- Used to check that two tables share the same shape (schema).
local function shape_eq(a, b, path)
    path = path or "$"
    local ta, tb = type(a), type(b)
    if ta ~= tb then return false, path .. ": " .. ta .. " vs " .. tb end
    if ta ~= "table" then return true end
    local seen = {}
    for k, va in pairs(a) do
        seen[k] = true
        if b[k] == nil then return false, path .. "." .. tostring(k) .. ": missing in b" end
        local ok, why = shape_eq(va, b[k], path .. "." .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if not seen[k] then
            return false, path .. "." .. tostring(k) .. ": missing in a"
        end
    end
    return true
end

function M.same_shape(a, b, msg)
    local ok, why = shape_eq(a, b)
    if not ok then fail(msg or "shape differs", "  " .. why) end
    return true
end

-- ===== Spec-name aliases + additional checks ==========================
--
-- The public spec requests `same`, `nil_`, `not_nil`, `is_a`, `not_match`,
-- `pcontains`, `empty`, `len`, plus custom-matcher registration.

M.same    = M.equal
M.is_type = M.is_type        -- already present; documented under spec name
M.is_a    = M.is_type        -- spec alias

function M.nil_(v, msg)     return M.is_nil(v, msg) end
function M.not_nil(v, msg)
    if v == nil then fail(msg or "expected not nil", "  got: nil") end
    return true
end

function M.not_match(s, pattern, msg)
    if type(s) ~= "string" then
        fail(msg or "not_match: expected string", "  got " .. type(s))
    end
    if string.match(s, pattern) then
        fail(msg or "pattern matched unexpectedly",
             "  string:  " .. pp(s) .. "\n  pattern: " .. pp(pattern))
    end
    return true
end

-- Pattern-based substring search; `pcontains(haystack, lua_pattern)`.
function M.pcontains(haystack, needle, msg)
    if type(haystack) ~= "string" then
        fail(msg or "pcontains: expected string", "  got " .. type(haystack))
    end
    if not string.find(haystack, needle) then
        fail(msg or "string does not contain pattern",
             "  haystack: " .. pp(haystack) .. "\n  pattern:  " .. pp(needle))
    end
    return true
end

function M.empty(t, msg)
    if type(t) == "string" then
        if #t ~= 0 then fail(msg or "expected empty string", "  got: " .. pp(t)) end
        return true
    end
    if type(t) ~= "table" then
        fail(msg or "empty: expected table or string", "  got " .. type(t))
    end
    if next(t) ~= nil then
        fail(msg or "expected empty table", "  got: " .. pp(t))
    end
    return true
end

M.len = M.length

-- Custom matchers are stored here; `Chain.__index` consults this table.
local _CUSTOM = {}

-- Custom matcher registration: `register("be_palindrome", fn)` -> available as
-- `M.be_palindrome(v, ...)` and as `:be_palindrome(...)` on the fluent chain.
function M.register(name, predicate)
    if type(name) ~= "string" or type(predicate) ~= "function" then
        error("assert_ex.register: (name:string, predicate:function)", 2)
    end
    M[name] = function(v, ...)
        local ok, why = predicate(v, ...)
        if not ok then fail("custom matcher '" .. name .. "' failed",
                            why and ("  " .. tostring(why)) or "") end
        return true
    end
    _CUSTOM[name] = predicate
end

-- Internal access for the Chain metatable defined below.
M._custom_matchers = _CUSTOM

function M.keys(t, expected_keys, msg)
    if type(t) ~= "table" then fail(msg or "keys: expected table", "  got " .. type(t)) end
    local present = {}
    for k in pairs(t) do present[k] = true end
    local missing, extra = {}, {}
    for _, k in ipairs(expected_keys) do
        if not present[k] then missing[#missing + 1] = k end
        present[k] = nil
    end
    for k in pairs(present) do extra[#extra + 1] = k end
    if #missing > 0 or #extra > 0 then
        fail(msg or "key set mismatch",
             "  missing: " .. pp(missing) .. "\n  extra:   " .. pp(extra))
    end
    return true
end

-- ===== Fluent chain ====================================================
--
-- `expect(v).to.equal(x).and_to.be.a("string")` -- the words `to`, `be`,
-- `and_to`, `is`, `that` are no-op grammar; they all return the chain.

local Chain = {}
Chain.__index = function(t, k)
    local v = rawget(Chain, k)
    if v ~= nil then return v end
    -- Custom matcher registered via M.register(name, predicate).
    local pred = _CUSTOM[k]
    if pred then
        -- Closure captures `t` (the chain). Method always uses the captured chain
        -- so it works for both `chain:foo(arg)` and `chain.foo(arg)` styles.
        local chain = t
        return function(maybe_self, ...)
            -- Detect colon vs dot call by checking if first arg is the chain.
            local nargs = select("#", maybe_self, ...)
            local ok
            if maybe_self == chain then
                ok = pred(chain._value, ...)
            else
                if nargs > 0 then
                    ok = pred(chain._value, maybe_self, ...)
                else
                    ok = pred(chain._value)
                end
            end
            if chain._neg then
                if ok then fail("custom matcher '" .. k .. "' should have failed", "") end
            else
                if not ok then fail("custom matcher '" .. k .. "' failed", "") end
            end
            return chain
        end
    end
    return nil
end

-- These words are pure sugar -- they let the user write English-ish chains.
-- NOTE: `a`/`an` are NOT sugar -- they are the documented type-check verb
-- (`.to.be.a("string")`), bound below to Chain:type. Listing them here made
-- `chain.a` resolve to the chain, so `.a("string")` raised "attempt to call a
-- table value".
local _SUGAR = { "to", "be", "is", "that", "and_to", "and_is", "with" }
-- Verbs that should also work via dot-syntax (auto-bound to self) so the
-- spec'd `.to.equal(x)` form works as written, not just `.to:equal(x)`.
local _VERBS = { "equal", "near", "truthy", "falsy", "type", "contain", "match",
                 "length", "throw", "not_" }

local function new_chain(value, negated)
    local c = setmetatable({ _value = value, _neg = negated or false }, Chain)
    -- sugar nouns: pre-resolve to the chain itself so `.to`, `.be`, etc. read fields
    for _, w in ipairs(_SUGAR) do c[w] = c end
    -- verb bindings: install per-instance closures so `chain.verb(args)` auto-passes self
    local function bind(method)
        return function(...)
            -- Detect colon vs dot: if first arg is this chain instance it's colon-call.
            local first = select(1, ...)
            if first == c then return method(c, select(2, ...)) end
            return method(c, ...)
        end
    end
    for _, v in ipairs(_VERBS) do
        c[v] = bind(Chain[v])
    end
    -- `a`/`an` are the documented type-check verb -> Chain:type.
    c.a  = bind(Chain.type)
    c.an = bind(Chain.type)
    return c
end

function Chain:_invert()
    return new_chain(self._value, not self._neg)
end

-- `:not_()` flips the polarity once. Cannot use `not` as a key (reserved word).
function Chain:not_()
    return self:_invert()
end

-- Run a predicate; if `_neg` is set, success/failure is inverted.
function Chain:_check(passed, ok_msg, fail_msg)
    local actually_passed = self._neg and (not passed) or passed
    if not actually_passed then
        if self._neg then fail(ok_msg or "expected not to pass", "")
        else fail(fail_msg or "expectation failed", "") end
    end
    return self
end

function Chain:equal(other, msg)
    local ok = deep_eq(self._value, other)
    if self._neg then
        if ok then fail(msg or "expected values to differ", "  both: " .. pp(self._value)) end
    else
        if not ok then
            local _, p, e, act = deep_eq(self._value, other)
            fail(msg or "expected equal",
                 string.format("  at %s\n  expected: %s\n  actual:   %s", p, e, act))
        end
    end
    return self
end

function Chain:near(other, eps, msg)
    eps = eps or 1e-9
    local ok = type(self._value) == "number" and type(other) == "number"
               and math.abs(self._value - other) <= eps
    return self:_check(ok, nil,
        msg or string.format("expected ~= %g (eps=%g), got %s", other, eps, tostring(self._value)))
end

function Chain:truthy(msg)
    return self:_check(self._value and true or false, nil, msg or "expected truthy")
end

function Chain:falsy(msg)
    return self:_check(not self._value, nil, msg or "expected falsy")
end

-- `:a("string")` / `:an("number")` -- type check.
function Chain:type(name, msg)
    return self:_check(type(self._value) == name, nil,
        msg or ("expected type " .. name .. ", got " .. type(self._value)))
end

function Chain:contain(needle, msg)
    local v = self._value
    local ok = false
    if type(v) == "string" then
        ok = string.find(v, needle, 1, true) ~= nil
    elseif type(v) == "table" then
        for _, item in pairs(v) do
            if deep_eq(item, needle) then ok = true; break end
        end
    end
    return self:_check(ok, nil, msg or "expected to contain " .. pp(needle))
end

function Chain:match(pattern, msg)
    local ok = type(self._value) == "string" and string.match(self._value, pattern) ~= nil
    return self:_check(ok, nil, msg or "expected to match " .. pp(pattern))
end

function Chain:length(n, msg)
    local got = (type(self._value) == "table" or type(self._value) == "string") and #self._value or nil
    return self:_check(got == n, nil,
        msg or string.format("expected length %d, got %s", n, tostring(got)))
end

function Chain:throw(pattern, msg)
    if type(self._value) ~= "function" then
        fail(msg or "expect:throw requires a function value", "  got " .. type(self._value))
    end
    local ok, err = pcall(self._value)
    if ok then
        if not self._neg then fail(msg or "expected function to throw", "") end
        return self
    end
    if pattern and not string.match(tostring(err), pattern) then
        fail(msg or "thrown error did not match pattern",
             "  pattern: " .. pp(pattern) .. "\n  error:   " .. pp(tostring(err)))
    end
    return self
end

function M.expect(v)
    return new_chain(v, false)
end

return M
