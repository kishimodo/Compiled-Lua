-- lpeg -- LPeg-compatible PEG library.
--
-- Tries to ffi.load lpeg54.dll / lpeg.dll; if neither is available we fall
-- back to a pure-Lua implementation that exposes the same constructors and
-- operator overloads. Either way, callers do:
--
--     local lpeg = require "lpeg"
--     local P, S, R, V = lpeg.P, lpeg.S, lpeg.R, lpeg.V
--     local pat = P"hello" * (P" " * R"AZ"^1 + P"")
--     print(lpeg.match(pat, "hello WORLD"))
--
-- Public surface:
--   P(v), S(set), R(range1, range2, ...), V(name), B(p)
--   C(p), Cs(p), Ct(p), Cg(p, name?), Cc(...), Cmt(p, fn), Cp()
--   match(pat, subject, init?)
--   type(p) -> "pattern" | nil
--   version()
--   locale()                    -- ASCII-only locale table for compatibility
--
-- Operators on patterns:
--   a * b   sequence
--   a + b   ordered choice
--   p ^ n   repetition: n>=0 = at least n, n<0 = at most -n
--   p - q   "p but not q"  (lookahead negation + match)
--   -p      negative lookahead
--   #p      positive lookahead (and-predicate)

local M = {}

-- ===== Native fast-path ================================================
-- If a C lpeg is available, expose its surface verbatim and skip the
-- pure-Lua implementation entirely.

local ok_native, native = pcall(require, "lpeg")
if ok_native and type(native) == "table" and native ~= M and native.match then
    -- Re-exporting verbatim preserves identity of constructed patterns,
    -- which lpeg.re and other downstream libraries depend on.
    return native
end

-- Try ffi-loading a known DLL and then re-requiring "lpeg". This covers
-- the case where the DLL is shipped via LuaVM's native package loader
-- but Lua's package.loaded["lpeg"] isn't pre-populated.
local function try_ffi_load()
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return nil end
    for _, name in ipairs({ "lpeg54", "lpeg" }) do
        local ok = pcall(ffi.load, name)
        if ok then
            local ok2, mod = pcall(require, "lpeg")
            if ok2 and type(mod) == "table" and mod.match then return mod end
        end
    end
    return nil
end

local injected = try_ffi_load()
if injected and injected.match then return injected end

-- ===== Pure-Lua fallback ===============================================
-- Pattern internal representation: a table with __index = Pattern_mt and:
--   { kind = "literal"|"set"|"range"|"any"|"true"|"false"|
--            "seq"|"alt"|"rep"|"and"|"not"|"diff"|
--            "v"|"behind"|
--            "c"|"cs"|"ct"|"cg"|"cc"|"cmt"|"cp",
--     ...kind-specific fields... }
--
-- A pattern is "executed" by calling pattern_run(p, state) which returns
-- next_pos | nil. Captures append to state.captures during the descent.

local Pattern = {}
Pattern.__index = Pattern
-- Tag used by `is_pattern` to recognize our objects. We avoid setting
-- __metatable here because that would hide the operator-overload metatable
-- from `getmetatable()`-based checks the dispatch performs.
local PATTERN_TAG = {}

local function new_pattern(t)
    t._tag = PATTERN_TAG
    return setmetatable(t, Pattern)
end

local function is_pattern(x) return type(x) == "table" and x._tag == PATTERN_TAG end

-- ----- Constructors (P / S / R / V / B) --------------------------------

local function P_lit(s)
    if s == "" then return new_pattern{ kind = "true" } end
    return new_pattern{ kind = "literal", text = s, len = #s }
end

local function P_n(n)
    -- P(n>=0): match exactly n characters; P(n<0): only succeed if fewer
    -- than -n characters remain (negative anchor).
    if n == 0 then return new_pattern{ kind = "true" } end
    if n > 0 then return new_pattern{ kind = "anyn", n = n } end
    return new_pattern{ kind = "behind_end", n = -n }
end

local function P_bool(b)
    return new_pattern{ kind = b and "true" or "false" }
end

local function P_fn(f)
    -- LPeg accepts a function as a match-time test. We model it as Cmt(P"", f).
    return new_pattern{ kind = "fn", fn = f }
end

local function P_any(v)
    local t = type(v)
    if t == "string" then return P_lit(v) end
    if t == "number" then return P_n(v) end
    if t == "boolean" then return P_bool(v) end
    if is_pattern(v) then return v end
    if t == "table" then
        -- Treat as a grammar: t[1] (or t.start) is the start rule key.
        return M.grammar(v)
    end
    if t == "function" then return P_fn(v) end
    error("lpeg.P: cannot convert " .. t .. " to pattern", 3)
end

M.P = P_any

function M.S(set)
    if type(set) ~= "string" then error("lpeg.S: expected string", 2) end
    local lut = {}
    for i = 1, #set do lut[set:byte(i)] = true end
    return new_pattern{ kind = "set", lut = lut }
end

function M.R(a, b, c, d, e, f, g, h)
    -- R("AZ") = bytes 'A'..'Z'; R("AZ","az") = union of both ranges.
    -- Explicit arity avoids LuaVM JIT's OP_SETLIST(B=0) limitation.
    local pairs_ = {}
    local args = { a, b, c, d, e, f, g, h }
    for i = 1, 8 do
        local r = args[i]
        if r == nil then break end
        if type(r) ~= "string" or #r ~= 2 then
            error("lpeg.R: each arg must be a 2-char string", 2)
        end
        local lo = r:byte(1)
        local hi = r:byte(2)
        pairs_[#pairs_ + 1] = { lo, hi }
    end
    return new_pattern{ kind = "range", pairs = pairs_ }
end

function M.V(name)
    return new_pattern{ kind = "v", name = name }
end

function M.B(p)
    -- Look-behind: succeeds at pos iff p matches the run ending right
    -- before pos. Only fixed-length patterns are supported, mirroring
    -- LPeg's documented restriction.
    local pat = P_any(p)
    return new_pattern{ kind = "behind", pat = pat }
end

-- ----- Captures --------------------------------------------------------

function M.C(p)
    return new_pattern{ kind = "c", pat = P_any(p) }
end

function M.Cs(p)
    return new_pattern{ kind = "cs", pat = P_any(p) }
end

function M.Ct(p)
    return new_pattern{ kind = "ct", pat = P_any(p) }
end

function M.Cg(p, name)
    return new_pattern{ kind = "cg", pat = P_any(p), name = name }
end

function M.Cc(...)
    -- Avoid `{n = ..., ...}` (LuaVM JIT doesn't yet support OP_SETLIST(B=0)).
    local n = select("#", ...)
    local values = { ... }
    values.n = n
    return new_pattern{ kind = "cc", values = values }
end

function M.Cp()
    return new_pattern{ kind = "cp" }
end

function M.Cmt(p, fn)
    return new_pattern{ kind = "cmt", pat = P_any(p), fn = fn }
end

-- ----- Operator overloads ---------------------------------------------

function Pattern.__mul(a, b)
    return new_pattern{ kind = "seq", left = P_any(a), right = P_any(b) }
end

function Pattern.__add(a, b)
    return new_pattern{ kind = "alt", left = P_any(a), right = P_any(b) }
end

function Pattern.__pow(p, n)
    return new_pattern{ kind = "rep", pat = P_any(p), n = n }
end

function Pattern.__div(p, x)
    -- p / x  : value capture that transforms the captures of p.
    --   string   -> %N substitution (a plain string with no %N just
    --               replaces the whole match); %0 is the whole match.
    --   function -> called with the captures; its returns become captures.
    --   table    -> the (first) capture is used as a key into the table.
    --   number   -> keep the Nth capture (0 = drop, keep nothing).
    return new_pattern{ kind = "div", pat = P_any(p), x = x }
end

function Pattern.__sub(a, b)
    -- a - b  ≡  -b * a
    return new_pattern{
        kind = "seq",
        left = new_pattern{ kind = "not", pat = P_any(b) },
        right = P_any(a),
    }
end

function Pattern.__unm(p)
    return new_pattern{ kind = "not", pat = p }
end

function Pattern.__len(p)
    return new_pattern{ kind = "and", pat = p }
end

-- ----- Grammar wrapper -------------------------------------------------

function M.grammar(t)
    -- LPeg conventions:
    --   * P{"S", S = pat, ...}  -> t[1] is the *name* of the start rule.
    --   * P{[1] = pat, ...}     -> t[1] is the start pattern itself.
    --   * P{start = pat, ...}   -> friendly alias used by this fallback.
    local start_key
    if type(t[1]) == "string" then
        start_key = t[1]
    elseif t[1] ~= nil then
        start_key = 1
    elseif t.start ~= nil then
        start_key = "start"
    else
        error("lpeg.P: grammar must have an entry [1] or .start", 3)
    end
    if t[start_key] == nil then
        error("lpeg.P: grammar start rule '" .. tostring(start_key) .. "' missing", 3)
    end
    return new_pattern{ kind = "grammar", rules = t, start = start_key }
end

-- ----- Engine ----------------------------------------------------------

local run

local function rollback_captures(captures, saved_n)
    for j = #captures, saved_n + 1, -1 do captures[j] = nil end
end

-- Compute the fixed match length of a pattern, or error if it has none.
-- Used by look-behind (B), which only accepts fixed-length patterns.
local function fixed_len(p)
    local k = p.kind
    if k == "literal" then return p.len
    elseif k == "anyn" then return p.n
    elseif k == "any" or k == "set" or k == "range" then return 1
    elseif k == "true" or k == "false" or k == "behind_end" then return 0
    elseif k == "seq" then return fixed_len(p.left) + fixed_len(p.right)
    elseif k == "alt" then
        local a = fixed_len(p.left)
        local b = fixed_len(p.right)
        if a ~= b then error("lpeg: look-behind pattern has no fixed length", 3) end
        return a
    elseif k == "and" or k == "not" then return 0
    elseif k == "diff" then return fixed_len(p.right or p.pat)
    elseif k == "c" or k == "cs" or k == "cg" or k == "cmt" or k == "div" then
        return fixed_len(p.pat)
    elseif k == "ct" then return fixed_len(p.pat)
    else
        error("lpeg: look-behind pattern has no fixed length", 3)
    end
end

run = function(p, st)
    local k = p.kind

    if k == "true" then
        return st.pos
    elseif k == "false" then
        return nil
    elseif k == "literal" then
        if st.input:sub(st.pos, st.pos + p.len - 1) == p.text then
            return st.pos + p.len
        end
        return nil
    elseif k == "anyn" then
        if st.pos + p.n - 1 <= #st.input then return st.pos + p.n end
        return nil
    elseif k == "behind_end" then
        -- P(-n) ≡ succeed if fewer than n chars remain.
        if #st.input - st.pos + 1 < p.n then return st.pos end
        return nil
    elseif k == "set" then
        local c = st.input:byte(st.pos)
        if c and p.lut[c] then return st.pos + 1 end
        return nil
    elseif k == "range" then
        local c = st.input:byte(st.pos)
        if c == nil then return nil end
        for _, pr in ipairs(p.pairs) do
            if c >= pr[1] and c <= pr[2] then return st.pos + 1 end
        end
        return nil
    elseif k == "seq" then
        local saved_pos = st.pos
        local saved_cap = #st.captures
        local m = run(p.left, st)
        if m == nil then
            st.pos = saved_pos
            rollback_captures(st.captures, saved_cap)
            return nil
        end
        st.pos = m
        local m2 = run(p.right, st)
        if m2 == nil then
            st.pos = saved_pos
            rollback_captures(st.captures, saved_cap)
            return nil
        end
        return m2
    elseif k == "alt" then
        local saved_pos = st.pos
        local saved_cap = #st.captures
        local m = run(p.left, st)
        if m ~= nil then return m end
        st.pos = saved_pos
        rollback_captures(st.captures, saved_cap)
        return run(p.right, st)
    elseif k == "rep" then
        local n = p.n
        local count = 0
        if n >= 0 then
            while true do
                local saved_pos = st.pos
                local saved_cap = #st.captures
                local m = run(p.pat, st)
                if m == nil or m == saved_pos then
                    st.pos = saved_pos
                    rollback_captures(st.captures, saved_cap)
                    break
                end
                st.pos = m
                count = count + 1
            end
            if count < n then return nil end
            return st.pos
        else
            -- at most -n times
            local limit = -n
            while count < limit do
                local saved_pos = st.pos
                local saved_cap = #st.captures
                local m = run(p.pat, st)
                if m == nil or m == saved_pos then
                    st.pos = saved_pos
                    rollback_captures(st.captures, saved_cap)
                    break
                end
                st.pos = m
                count = count + 1
            end
            return st.pos
        end
    elseif k == "and" then
        local saved_pos = st.pos
        local saved_cap = #st.captures
        local m = run(p.pat, st)
        st.pos = saved_pos
        rollback_captures(st.captures, saved_cap)
        if m ~= nil then return saved_pos end
        return nil
    elseif k == "not" then
        local saved_pos = st.pos
        local saved_cap = #st.captures
        local m = run(p.pat, st)
        st.pos = saved_pos
        rollback_captures(st.captures, saved_cap)
        if m == nil then return saved_pos end
        return nil
    elseif k == "v" then
        local rule = st.grammar and st.grammar.rules[p.name]
        if rule == nil then
            error("lpeg: undefined rule '" .. tostring(p.name) .. "'", 3)
        end
        return run(rule, st)
    elseif k == "behind" then
        -- Fixed-length look-behind: compute the pattern's exact length and
        -- probe that many bytes back, requiring it to end exactly at st.pos.
        local len = fixed_len(p.pat)
        local probe = st.pos - len
        if probe < 1 then return nil end
        local saved_pos = st.pos
        st.pos = probe
        local m = run(p.pat, st)
        st.pos = saved_pos
        if m == saved_pos then return saved_pos end
        return nil
    elseif k == "fn" then
        local v = p.fn(st.input, st.pos)
        if v == nil or v == false then return nil end
        if v == true then return st.pos end
        if type(v) == "number" then return v end
        return nil
    elseif k == "grammar" then
        local old = st.grammar
        st.grammar = p
        local start_rule = p.rules[p.start]
        local m = run(start_rule, st)
        st.grammar = old
        return m
    elseif k == "c" then
        local start = st.pos
        local m = run(p.pat, st)
        if m == nil then return nil end
        -- spos/epos record the matched span so an enclosing Cs can splice it.
        st.captures[#st.captures + 1] = {
            kind = "value", value = st.input:sub(start, m - 1), spos = start, epos = m,
        }
        return m
    elseif k == "cs" then
        local start = st.pos
        local saved_cap = #st.captures
        local m = run(p.pat, st)
        if m == nil then return nil end
        -- Substitution: each value-capture inside this region replaces the
        -- text it spans with its value; text not covered by any capture is
        -- kept verbatim. Captures carry spos/epos so we can splice in order.
        local parts = {}
        local cursor = start
        local spliced = false
        for i = saved_cap + 1, #st.captures do
            local c = st.captures[i]
            if c.kind == "value" and c.spos ~= nil then
                spliced = true
                if c.spos > cursor then
                    parts[#parts + 1] = st.input:sub(cursor, c.spos - 1)
                end
                parts[#parts + 1] = tostring(c.value)
                cursor = c.epos
            end
        end
        rollback_captures(st.captures, saved_cap)
        local merged
        if spliced then
            if m > cursor then parts[#parts + 1] = st.input:sub(cursor, m - 1) end
            merged = table.concat(parts)
        else
            merged = st.input:sub(start, m - 1)
        end
        st.captures[#st.captures + 1] = { kind = "value", value = merged }
        return m
    elseif k == "ct" then
        local saved_cap = #st.captures
        local m = run(p.pat, st)
        if m == nil then return nil end
        local tbl = {}
        local idx = 1
        for i = saved_cap + 1, #st.captures do
            local c = st.captures[i]
            if c.kind == "value" then
                tbl[idx] = c.value
                idx = idx + 1
            elseif c.kind == "group" and c.name ~= nil then
                tbl[c.name] = c.value
            end
        end
        rollback_captures(st.captures, saved_cap)
        st.captures[#st.captures + 1] = { kind = "value", value = tbl }
        return m
    elseif k == "cg" then
        local saved_cap = #st.captures
        local start = st.pos
        local m = run(p.pat, st)
        if m == nil then return nil end
        -- Pick the first value-captured payload, or fall back to the matched substring.
        local val
        for i = saved_cap + 1, #st.captures do
            if st.captures[i].kind == "value" then
                val = st.captures[i].value
                break
            end
        end
        if val == nil then val = st.input:sub(start, m - 1) end
        rollback_captures(st.captures, saved_cap)
        if p.name == nil then
            -- anonymous group: emits the inner value(s) as one capture
            st.captures[#st.captures + 1] = { kind = "value", value = val }
        else
            st.captures[#st.captures + 1] = { kind = "group", name = p.name, value = val }
        end
        return m
    elseif k == "cc" then
        for i = 1, p.values.n do
            st.captures[#st.captures + 1] = { kind = "value", value = p.values[i] }
        end
        return st.pos
    elseif k == "cp" then
        st.captures[#st.captures + 1] = { kind = "value", value = st.pos }
        return st.pos
    elseif k == "cmt" then
        local start = st.pos
        local saved_cap = #st.captures
        local m = run(p.pat, st)
        if m == nil then return nil end
        local matched = st.input:sub(start, m - 1)
        local ok, rv = pcall(p.fn, st.input, m, matched)
        if not ok then
            rollback_captures(st.captures, saved_cap)
            error(rv, 0)
        end
        if rv == nil or rv == false then
            st.pos = start
            rollback_captures(st.captures, saved_cap)
            return nil
        end
        if rv == true then return m end
        if type(rv) == "number" then return rv end
        st.captures[#st.captures + 1] = { kind = "value", value = rv }
        return m
    elseif k == "div" then
        local start = st.pos
        local saved_cap = #st.captures
        local m = run(p.pat, st)
        if m == nil then return nil end
        local whole = st.input:sub(start, m - 1)
        -- Gather the value captures produced by p; with none, the single
        -- "capture" passed to the transform is the whole matched substring.
        local vals = {}
        for i = saved_cap + 1, #st.captures do
            if st.captures[i].kind == "value" then
                vals[#vals + 1] = st.captures[i].value
            end
        end
        if #vals == 0 then vals[1] = whole end
        rollback_captures(st.captures, saved_cap)
        local tx = type(p.x)
        if tx == "string" then
            -- %0 -> whole match, %N -> Nth capture; plain text otherwise.
            local out = p.x:gsub("%%([%%0-9])", function(d)
                if d == "%" then return "%" end
                local n = tonumber(d)
                if n == 0 then return whole end
                return tostring(vals[n] ~= nil and vals[n] or "")
            end)
            st.captures[#st.captures + 1] = { kind = "value", value = out, spos = start, epos = m }
        elseif tx == "function" then
            local rets = { p.x(table.unpack(vals)) }
            for i = 1, #rets do
                st.captures[#st.captures + 1] = {
                    kind = "value", value = rets[i], spos = start, epos = m,
                }
            end
        elseif tx == "table" then
            -- The (first) capture indexes the table.
            st.captures[#st.captures + 1] = {
                kind = "value", value = p.x[vals[1]], spos = start, epos = m,
            }
        elseif tx == "number" then
            -- Keep the Nth capture (0 keeps nothing).
            if p.x >= 1 and vals[p.x] ~= nil then
                st.captures[#st.captures + 1] = {
                    kind = "value", value = vals[p.x], spos = start, epos = m,
                }
            end
        else
            error("lpeg: '/' rhs must be string/function/table/number", 2)
        end
        return m
    end
    error("lpeg: internal -- unknown pattern kind '" .. tostring(k) .. "'", 2)
end

function M.match(pat, subject, init)
    local p = P_any(pat)
    local st = {
        input = subject,
        pos   = init or 1,
        captures = {},
        grammar = nil,
    }
    if st.pos < 1 then st.pos = #subject + st.pos + 1 end
    if st.pos < 1 then st.pos = 1 end
    local endpos = run(p, st)
    if endpos == nil then return nil end
    if #st.captures == 0 then return endpos end
    if #st.captures == 1 then return st.captures[1].value end
    local results = {}
    for i, c in ipairs(st.captures) do results[i] = c.value end
    return table.unpack(results)
end

function M.type(x)
    if is_pattern(x) then return "pattern" end
    return nil
end

function M.version()
    return "1.0 (LuaVM pure-Lua fallback)"
end

function M.locale(t)
    -- LPeg's locale() returns a table with alnum / alpha / digit / ... patterns.
    -- We provide ASCII-only equivalents that match the LPeg API surface.
    t = t or {}
    t.alpha  = M.R("AZ", "az")
    t.upper  = M.R("AZ")
    t.lower  = M.R("az")
    t.digit  = M.R("09")
    t.alnum  = M.R("AZ", "az", "09")
    t.xdigit = M.R("09", "AF", "af")
    t.space  = M.S(" \t\r\n\v\f")
    t.cntrl  = M.R("\0\31") + P_any("\127")
    t.print  = M.R(" ~")
    t.punct  = M.S("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
    return t
end

return M
