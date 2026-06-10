-- expr -- sandboxed expression evaluator.
--
-- SECURITY NOTE:
--   This module intentionally evaluates user-supplied expression text. It is
--   safe-by-design via three layers: (1) a hand-written recursive-descent
--   parser rejects anything that is not a pure expression (no loops, no
--   assignments, no function/table definitions, no globals reference); (2)
--   the emitted Lua chunk references identifiers and calls *only* through
--   the local helpers __get and __call -- no bare name access; (3) the chunk
--   is loaded with an empty _ENV, so even if the parser had a bug the only
--   reachable values are the two helpers themselves. Calls are gated by an
--   explicit allowlist that defaults to "none". This is the sandbox; do not
--   bypass it by feeding the source to `load` directly.
--
-- Public surface (low-level, compile-to-function):
--   expr.compile(source, opts?) -> fn(env) | nil, err
--   expr.eval(source, env, opts?) -> result | nil, err
--
-- Public surface (high-level, evaluator object):
--   expr.compile_evaluator(source, opts?) -> evaluator | nil, err
--   evaluator:eval(context)   -> result | nil, err
--   evaluator:variables()     -> { "name1", "name2", ... }
--   evaluator:source()        -> original source string
--
-- The opts table for the high-level API uses friendlier names:
--   { functions = {...}, max_complexity = N, allow_globals = false }
-- functions is forwarded as allow_functions; max_complexity becomes max_depth.
--
-- opts:
--   allow_functions = false | true | "safe" | { name=fn, ... }
--      false (default)  -- no calls at all
--      true             -- any identifier in env that is callable can be called
--      "safe"           -- the bundled safe_funcs table (math + string basics)
--      table            -- explicit allowlist
--   allow_globals  = false (default). When true, the evaluator falls back to
--                    _G after env lookup misses -- generally a bad idea, hence
--                    off by default.
--   max_depth      = 20  -- guard against pathological nesting in the parser.
--
-- Operators supported (Lua precedence):
--   or
--   and
--   <  >  <=  >=  ==  ~=
--   ..                                      (right assoc, string concat)
--   +  -
--   *  /  %
--   not  #  unary -
--   ^                                       (right assoc)
--
-- Primaries: numbers, single/double quoted strings, true/false/nil,
-- identifiers, parenthesized expressions, table indexing (.field, [expr]),
-- function calls f(a, b, ...).
--
-- The strategy: parse -> rewrite to a Lua source string that references only
-- env.x for identifiers -> load with an empty _ENV. Calls go through a helper
-- that consults the allowlist. This means the host Lua arithmetic/coercion
-- rules apply identically -- we lean on Lua's interpreter for correctness.

local M = {}

local sub    = string.sub
local byte   = string.byte
local format = string.format
local concat = table.concat
local load_  = load

-- ===== Lexer ============================================================
--
-- Single-pass tokenizer. We could parse directly off the source but having
-- a token stream makes the recursive-descent code drastically cleaner and
-- the parser is the part we want to keep airtight.

local KEYWORDS = {
    ["and"] = true, ["or"] = true, ["not"] = true,
    ["true"] = true, ["false"] = true, ["nil"] = true,
}

local function lex(src)
    local tokens = {}
    local i, n = 1, #src
    while i <= n do
        local c = byte(src, i)
        -- whitespace
        if c == 32 or c == 9 or c == 10 or c == 13 then
            i = i + 1
        -- number
        elseif (c >= 48 and c <= 57) or (c == 46 and byte(src, i + 1) and byte(src, i + 1) >= 48 and byte(src, i + 1) <= 57) then
            local s = i
            -- 0x hex form
            if c == 48 and (byte(src, i + 1) == 120 or byte(src, i + 1) == 88) then
                i = i + 2
                while i <= n do
                    local b = byte(src, i)
                    if (b >= 48 and b <= 57) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102) then
                        i = i + 1
                    else break end
                end
            else
                while i <= n do
                    local b = byte(src, i)
                    if b >= 48 and b <= 57 then i = i + 1 else break end
                end
                if byte(src, i) == 46 then
                    i = i + 1
                    while i <= n do
                        local b = byte(src, i)
                        if b >= 48 and b <= 57 then i = i + 1 else break end
                    end
                end
                if byte(src, i) == 101 or byte(src, i) == 69 then
                    i = i + 1
                    if byte(src, i) == 43 or byte(src, i) == 45 then i = i + 1 end
                    while i <= n do
                        local b = byte(src, i)
                        if b >= 48 and b <= 57 then i = i + 1 else break end
                    end
                end
            end
            local txt = sub(src, s, i - 1)
            local num = tonumber(txt)
            if not num then return nil, "bad number: " .. txt end
            tokens[#tokens + 1] = { kind = "num", value = num }
        -- string
        elseif c == 34 or c == 39 then
            local quote = c
            local s = i + 1
            i = s
            local out, parts = nil, nil
            while i <= n and byte(src, i) ~= quote do
                if byte(src, i) == 92 then
                    -- handle escapes the same way Lua does for these basics
                    parts = parts or { sub(src, s, i - 1) }
                    if parts[1] == nil then parts[1] = sub(src, s, i - 1) end
                    local nc = byte(src, i + 1)
                    if nc == 110 then parts[#parts + 1] = "\n"
                    elseif nc == 116 then parts[#parts + 1] = "\t"
                    elseif nc == 114 then parts[#parts + 1] = "\r"
                    elseif nc == 34 then parts[#parts + 1] = "\""
                    elseif nc == 39 then parts[#parts + 1] = "'"
                    elseif nc == 92 then parts[#parts + 1] = "\\"
                    elseif nc == 48 then parts[#parts + 1] = "\0"
                    else return nil, "bad escape \\" .. string.char(nc or 0) end
                    i = i + 2
                    s = i
                else
                    i = i + 1
                end
            end
            if i > n then return nil, "unterminated string" end
            if parts then
                parts[#parts + 1] = sub(src, s, i - 1)
                out = concat(parts)
            else
                out = sub(src, s, i - 1)
            end
            i = i + 1
            tokens[#tokens + 1] = { kind = "str", value = out }
        -- identifier / keyword
        elseif (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 then
            local s = i
            i = i + 1
            while i <= n do
                local b = byte(src, i)
                if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or b == 95 then
                    i = i + 1
                else break end
            end
            local txt = sub(src, s, i - 1)
            if KEYWORDS[txt] then
                tokens[#tokens + 1] = { kind = txt }
            else
                tokens[#tokens + 1] = { kind = "id", value = txt }
            end
        -- multi-char operators
        elseif c == 61 and byte(src, i + 1) == 61 then  -- ==
            tokens[#tokens + 1] = { kind = "==" }; i = i + 2
        elseif c == 126 and byte(src, i + 1) == 61 then -- ~=
            tokens[#tokens + 1] = { kind = "~=" }; i = i + 2
        elseif c == 60 and byte(src, i + 1) == 61 then  -- <=
            tokens[#tokens + 1] = { kind = "<=" }; i = i + 2
        elseif c == 62 and byte(src, i + 1) == 61 then  -- >=
            tokens[#tokens + 1] = { kind = ">=" }; i = i + 2
        elseif c == 46 and byte(src, i + 1) == 46 then  -- ..
            tokens[#tokens + 1] = { kind = ".." }; i = i + 2
        -- single-char tokens
        elseif c == 43 or c == 45 or c == 42 or c == 47 or c == 37 or c == 94
            or c == 60 or c == 62 or c == 40 or c == 41 or c == 91 or c == 93
            or c == 44 or c == 46 or c == 35 then
            tokens[#tokens + 1] = { kind = string.char(c) }
            i = i + 1
        else
            return nil, "unexpected character '" .. string.char(c) .. "' at " .. i
        end
    end
    tokens[#tokens + 1] = { kind = "eof" }
    return tokens
end

-- ===== Parser ===========================================================
--
-- Output: a Lua source string that, when loaded with the right env, evaluates
-- to the same value as the original expression. Identifiers become __env_get
-- calls, calls become __call_safe calls. This indirection is what keeps the
-- sandbox honest -- the chunk never references _G or globals.

local function new_parser(tokens, opts)
    return {
        toks      = tokens,
        pos       = 1,
        depth     = 0,
        max_depth = opts.max_depth or 20,
    }
end

local function peek(p) return p.toks[p.pos] end
local function advance(p) local t = p.toks[p.pos]; p.pos = p.pos + 1; return t end
local function check(p, kind) return p.toks[p.pos].kind == kind end

local function expect(p, kind)
    local t = p.toks[p.pos]
    if t.kind ~= kind then
        return nil, "expected '" .. kind .. "' got '" .. tostring(t.kind) .. "'"
    end
    p.pos = p.pos + 1
    return t
end

local parse_or     -- forward decl, entry point
local parse_unary  -- forward decl, used by parse_power before its definition

local function enter(p)
    p.depth = p.depth + 1
    if p.depth > p.max_depth then
        error("expr: max depth " .. p.max_depth .. " exceeded")
    end
end
local function leave(p) p.depth = p.depth - 1 end

-- Escape a Lua string literal for emission into the generated chunk.
local function qlit(s)
    return format("%q", s)
end

-- primary := number | string | true | false | nil
--          | "(" expr ")"
--          | id { suffix }
-- suffix  := "." id | "[" expr "]" | "(" args ")"
local function parse_primary(p)
    enter(p)
    local t = peek(p)
    local out

    if t.kind == "num" then
        advance(p); out = tostring(t.value)
    elseif t.kind == "str" then
        advance(p); out = qlit(t.value)
    elseif t.kind == "true" then
        advance(p); out = "true"
    elseif t.kind == "false" then
        advance(p); out = "false"
    elseif t.kind == "nil" then
        advance(p); out = "nil"
    elseif t.kind == "(" then
        advance(p)
        local inner, err = parse_or(p)
        if not inner then leave(p); return nil, err end
        local _, err2 = expect(p, ")")
        if err2 then leave(p); return nil, err2 end
        out = "(" .. inner .. ")"
    elseif t.kind == "id" then
        advance(p)
        -- Bare identifier resolves through env; emit a getter so a sandboxed
        -- chunk never names a global directly.
        out = "__get(" .. qlit(t.value) .. ")"
    else
        leave(p); return nil, "unexpected token '" .. tostring(t.kind) .. "'"
    end

    -- suffixes: chained indexing and a single call site per primary
    while true do
        local nx = peek(p).kind
        if nx == "." then
            advance(p)
            local id, err = expect(p, "id")
            if err then leave(p); return nil, err end
            out = out .. "[" .. qlit(id.value) .. "]"
        elseif nx == "[" then
            advance(p)
            local idx, err = parse_or(p)
            if not idx then leave(p); return nil, err end
            local _, err2 = expect(p, "]")
            if err2 then leave(p); return nil, err2 end
            out = out .. "[" .. idx .. "]"
        elseif nx == "(" then
            advance(p)
            local args = {}
            if not check(p, ")") then
                while true do
                    local a, err = parse_or(p)
                    if not a then leave(p); return nil, err end
                    args[#args + 1] = a
                    if check(p, ",") then advance(p)
                    else break end
                end
            end
            local _, err = expect(p, ")")
            if err then leave(p); return nil, err end
            -- Route every call through the sandbox so the allowlist is
            -- consulted even for env-table callables.
            out = "__call(" .. out
            if #args > 0 then out = out .. "," .. concat(args, ",") end
            out = out .. ")"
        else
            break
        end
    end

    leave(p)
    return out
end

-- unary := ("not"|"-"|"#") unary | power
-- power := primary ("^" unary)?       -- right-assoc
local function parse_power(p)
    local lhs, err = parse_primary(p)
    if not lhs then return nil, err end
    if peek(p).kind == "^" then
        advance(p)
        local rhs, err2 = parse_unary(p)  -- right assoc -> recurse on unary
        if not rhs then return nil, err2 end
        return "(" .. lhs .. "^" .. rhs .. ")"
    end
    return lhs
end

function parse_unary(p)
    local k = peek(p).kind
    if k == "not" or k == "-" or k == "#" then
        advance(p)
        local rhs, err = parse_unary(p)
        if not rhs then return nil, err end
        if k == "not" then return "(not " .. rhs .. ")"
        elseif k == "-" then return "(-(" .. rhs .. "))"
        else return "(#(" .. rhs .. "))" end
    end
    return parse_power(p)
end

local function parse_mul(p)
    local lhs, err = parse_unary(p)
    if not lhs then return nil, err end
    while peek(p).kind == "*" or peek(p).kind == "/" or peek(p).kind == "%" do
        local op = advance(p).kind
        local rhs, err2 = parse_unary(p)
        if not rhs then return nil, err2 end
        lhs = "(" .. lhs .. op .. rhs .. ")"
    end
    return lhs
end

local function parse_add(p)
    local lhs, err = parse_mul(p)
    if not lhs then return nil, err end
    while peek(p).kind == "+" or peek(p).kind == "-" do
        local op = advance(p).kind
        local rhs, err2 = parse_mul(p)
        if not rhs then return nil, err2 end
        lhs = "(" .. lhs .. op .. rhs .. ")"
    end
    return lhs
end

-- right-assoc -- recurse on self.
local function parse_concat(p)
    local lhs, err = parse_add(p)
    if not lhs then return nil, err end
    if peek(p).kind == ".." then
        advance(p)
        local rhs, err2 = parse_concat(p)
        if not rhs then return nil, err2 end
        -- spaces around '..' are REQUIRED: with a number on the left, "1"..".."
        -- yields "1.." which Lua lexes as a malformed number.
        return "(" .. lhs .. " .. " .. rhs .. ")"
    end
    return lhs
end

local CMP_OPS = { ["<"] = true, [">"] = true, ["<="] = true, [">="] = true, ["=="] = true, ["~="] = true }

local function parse_cmp(p)
    local lhs, err = parse_concat(p)
    if not lhs then return nil, err end
    while CMP_OPS[peek(p).kind] do
        local op = advance(p).kind
        local rhs, err2 = parse_concat(p)
        if not rhs then return nil, err2 end
        lhs = "(" .. lhs .. op .. rhs .. ")"
    end
    return lhs
end

local function parse_and(p)
    local lhs, err = parse_cmp(p)
    if not lhs then return nil, err end
    while peek(p).kind == "and" do
        advance(p)
        local rhs, err2 = parse_cmp(p)
        if not rhs then return nil, err2 end
        lhs = "(" .. lhs .. " and " .. rhs .. ")"
    end
    return lhs
end

function parse_or(p)
    local lhs, err = parse_and(p)
    if not lhs then return nil, err end
    while peek(p).kind == "or" do
        advance(p)
        local rhs, err2 = parse_and(p)
        if not rhs then return nil, err2 end
        lhs = "(" .. lhs .. " or " .. rhs .. ")"
    end
    return lhs
end

-- ===== Safe defaults ====================================================
--
-- "safe" allowlist: a tiny vetted slice of math/string/table that is
-- side-effect-free and won't leak references back to globals.

local SAFE_FUNCS = {
    abs = math.abs, ceil = math.ceil, floor = math.floor, max = math.max,
    min = math.min, sqrt = math.sqrt, exp = math.exp, log = math.log,
    sin = math.sin, cos = math.cos, tan = math.tan, pi = math.pi,
    pow = function(a, b) return a ^ b end,
    len = function(s) return #s end,
    upper = string.upper, lower = string.lower, rep = string.rep,
    sub = string.sub, find = function(s, p) return string.find(s, p, 1, true) end,
    tonumber = tonumber, tostring = tostring, type = type,
    concat = function(t, sep) return table.concat(t, sep or "") end,
}
M.safe_funcs = SAFE_FUNCS

-- ===== Public API =======================================================

function M.compile(source, opts)
    opts = opts or {}
    if type(source) ~= "string" then return nil, "source must be a string" end

    local toks, err = lex(source)
    if not toks then return nil, err end

    local p = new_parser(toks, opts)
    local ok, body_or_err = pcall(parse_or, p)
    if not ok then return nil, tostring(body_or_err) end
    local body = body_or_err
    if not body then return nil, "parse failed" end

    if peek(p).kind ~= "eof" then
        return nil, "trailing tokens after expression"
    end

    local chunk_src = "return (" .. body .. ")"

    -- Resolve allow_functions into a single callable predicate
    local allow_globals = opts.allow_globals == true
    local af = opts.allow_functions
    local allow_kind
    if af == nil or af == false then
        allow_kind = "none"
    elseif af == true then
        allow_kind = "any"
    elseif af == "safe" then
        allow_kind = "table"; af = SAFE_FUNCS
    elseif type(af) == "table" then
        allow_kind = "table"
    elseif type(af) == "function" then
        allow_kind = "predicate"
    else
        return nil, "bad allow_functions"
    end

    -- Precompute a value-set of allowed functions ONCE (here, not per call):
    -- the membership test in __call is then an O(1) lookup instead of a
    -- generic-for scan over `af` on every call.
    local af_set
    if allow_kind == "table" then
        af_set = {}
        for _, f in pairs(af) do af_set[f] = true end
    end

    -- Return a closure -- one parsed expression, reusable across envs.
    return function(env)
        env = env or {}
        local function __get(name)
            local v = env[name]
            if v ~= nil then return v end
            if allow_globals then return _G[name] end
            return nil
        end
        local function __call(fn, ...)
            if type(fn) ~= "function" then
                error("expr: attempt to call non-function value")
            end
            if allow_kind == "none" then
                error("expr: function calls are disabled")
            elseif allow_kind == "any" then
                return fn(...)
            elseif allow_kind == "table" then
                if not af_set[fn] then error("expr: function not in allowlist") end
                return fn(...)
            else  -- predicate
                if not af(fn) then error("expr: function rejected by predicate") end
                return fn(...)
            end
        end

        -- Build a minimal env for the chunk; no _G, no inherited upvalues.
        local chunk_env = { __get = __get, __call = __call }
        local chunk, lerr = load_(chunk_src, "=expr", "t", chunk_env)
        if not chunk then return nil, lerr end
        local ok2, val = pcall(chunk)
        if not ok2 then return nil, tostring(val) end
        return val
    end
end

function M.eval(source, env, opts)
    local fn, err = M.compile(source, opts)
    if not fn then return nil, err end
    return fn(env)
end

-- ===== High-level evaluator object ======================================
--
-- Wraps compile() in an object so callers can introspect referenced
-- variables and reuse the evaluator across many contexts. The sandbox is
-- identical to compile(); this layer is convenience only.

-- Walk the token stream to extract bare identifier names that are *read*
-- (i.e. not used as call targets). We treat `foo(...)` as a function call
-- (excluded from variables), and `obj.field` so only `obj` is included.
local function collect_variables(tokens)
    local seen, vars = {}, {}
    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        if t.kind == "id" then
            -- Skip if it's a method/field access after a dot: `a.b` -> b is field.
            local prev = tokens[i - 1]
            if not (prev and prev.kind == ".") then
                if not seen[t.value] then
                    seen[t.value] = true
                    vars[#vars + 1] = t.value
                end
            end
        end
        i = i + 1
    end
    return vars
end

local Evaluator = {}
Evaluator.__index = Evaluator

function Evaluator:eval(context)
    return self._fn(context)
end

function Evaluator:variables()
    -- Defensive copy so callers can't mutate the cached list.
    local out = {}
    for i = 1, #self._vars do out[i] = self._vars[i] end
    return out
end

function Evaluator:source()
    return self._source
end

function M.compile_evaluator(source, opts)
    opts = opts or {}
    -- Translate friendly opt names to compile()'s internal names without
    -- mutating the caller's table.
    local inner_opts = {
        allow_functions = opts.functions or opts.allow_functions,
        allow_globals   = opts.allow_globals,
        max_depth       = opts.max_complexity or opts.max_depth,
    }
    -- Pre-lex once so we can both compile and collect variables; lex is
    -- pure and inexpensive.
    if type(source) ~= "string" then return nil, "source must be a string" end
    local toks, lerr = lex(source)
    if not toks then return nil, lerr end

    local fn, cerr = M.compile(source, inner_opts)
    if not fn then return nil, cerr end

    return setmetatable({
        _fn     = fn,
        _vars   = collect_variables(toks),
        _source = source,
    }, Evaluator)
end

return M
