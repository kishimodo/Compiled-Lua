-- peg -- Pure-Lua PEG parser combinators.
--
-- A parser is internally a function:
--     parser(state) -> next_pos | nil
-- where state is a shared table:
--     { input = "...", pos = 1, captures = {}, defs = <grammar rules>, names = <group name stack> }
-- Returning nil signals failure; returning the next byte position signals
-- success and advances the cursor. Captures are appended in-order to
-- state.captures during the descent.
--
-- We use a plain-function representation (no metatables) because PEG
-- combinators compose heavily and the per-call overhead of __call is
-- meaningful at parse time.
--
-- Public surface:
--   peg.lit(s)        -- match literal string s
--   peg.range(a, b)   -- match a single byte in [a, b] (inclusive, by char)
--   peg.set(chars)    -- match a single byte appearing in chars
--   peg.any()         -- match any single byte (fails only at EOF)
--   peg.seq(...)      -- ordered concatenation, all sub-parsers must succeed
--   peg.alt(...)      -- ordered alternation, first success wins (no backtracking past it)
--   peg.star(p)       -- greedy zero-or-more
--   peg.plus(p)       -- greedy one-or-more
--   peg.opt(p)        -- zero-or-one
--   peg.not_(p)       -- negative lookahead, never consumes
--   peg.and_(p)       -- positive lookahead, never consumes
--   peg.cap(p)        -- capture the result of p as-is (raw substring)
--   peg.cap_str(p)    -- alias of cap (kept for readability)
--   peg.cap_pos()     -- capture current byte position
--   peg.group(p, n)   -- run p; emit captures keyed under group name n
--   peg.ref(name)     -- forward reference to a rule in the enclosing grammar
--   peg.grammar(t)    -- bake a rule table into a parser (t.start = entrypoint)
--   peg.match(g, s)   -- run grammar g against s; return captures, endpos
--
-- Helpers (built on top of the combinators above):
--   peg.whitespace()      -- one or more ASCII whitespace bytes
--   peg.identifier()      -- [A-Za-z_][A-Za-z0-9_]*
--   peg.number()          -- signed integer or float with optional exponent
--   peg.quoted_string()   -- "..." with standard backslash escapes

local M = {}

-- ===== Core primitives =================================================

function M.lit(s)
    local n = #s
    return function(st)
        if st.input:sub(st.pos, st.pos + n - 1) == s then
            return st.pos + n
        end
        return nil
    end
end

function M.range(a, b)
    local lo = type(a) == "string" and a:byte() or a
    local hi = type(b) == "string" and b:byte() or b
    return function(st)
        local c = st.input:byte(st.pos)
        if c and c >= lo and c <= hi then
            return st.pos + 1
        end
        return nil
    end
end

function M.set(chars)
    -- Pre-build a lookup table so each parse step is O(1).
    local lut = {}
    for i = 1, #chars do lut[chars:byte(i)] = true end
    return function(st)
        local c = st.input:byte(st.pos)
        if c and lut[c] then return st.pos + 1 end
        return nil
    end
end

function M.any()
    return function(st)
        if st.pos <= #st.input then return st.pos + 1 end
        return nil
    end
end

function M.seq(...)
    -- CLua JIT does not support OP_SETLIST(B=0) from `{...}`, so collect
    -- via select() into a fresh table.
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = (select(i, ...)) end
    return function(st)
        local saved_pos      = st.pos
        local saved_cap_len  = #st.captures
        for i = 1, n do
            local np = parts[i](st)
            if np == nil then
                -- rollback both position and any captures emitted by earlier parts
                st.pos = saved_pos
                for j = #st.captures, saved_cap_len + 1, -1 do st.captures[j] = nil end
                return nil
            end
            st.pos = np
        end
        return st.pos
    end
end

function M.alt(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = (select(i, ...)) end
    return function(st)
        local saved_pos     = st.pos
        local saved_cap_len = #st.captures
        for i = 1, n do
            local np = parts[i](st)
            if np ~= nil then return np end
            -- branch failed, clean up before trying next
            st.pos = saved_pos
            for j = #st.captures, saved_cap_len + 1, -1 do st.captures[j] = nil end
        end
        return nil
    end
end

function M.star(p)
    return function(st)
        while true do
            local saved_pos     = st.pos
            local saved_cap_len = #st.captures
            local np = p(st)
            if np == nil or np == saved_pos then
                -- zero-progress match must terminate or we loop forever
                st.pos = saved_pos
                for j = #st.captures, saved_cap_len + 1, -1 do st.captures[j] = nil end
                return st.pos
            end
            st.pos = np
        end
    end
end

function M.plus(p)
    local star = M.star(p)
    return function(st)
        local first = p(st)
        if first == nil then return nil end
        st.pos = first
        return star(st)
    end
end

function M.opt(p)
    return function(st)
        local saved_pos     = st.pos
        local saved_cap_len = #st.captures
        local np = p(st)
        if np == nil then
            st.pos = saved_pos
            for j = #st.captures, saved_cap_len + 1, -1 do st.captures[j] = nil end
            return saved_pos
        end
        return np
    end
end

function M.not_(p)
    return function(st)
        local saved_pos     = st.pos
        local saved_cap_len = #st.captures
        local np = p(st)
        -- never advance, never keep sub-captures
        st.pos = saved_pos
        for j = #st.captures, saved_cap_len + 1, -1 do st.captures[j] = nil end
        if np == nil then return saved_pos end
        return nil
    end
end

function M.and_(p)
    return function(st)
        local saved_pos     = st.pos
        local saved_cap_len = #st.captures
        local np = p(st)
        st.pos = saved_pos
        for j = #st.captures, saved_cap_len + 1, -1 do st.captures[j] = nil end
        if np ~= nil then return saved_pos end
        return nil
    end
end

-- ===== Captures ========================================================

function M.cap(p)
    return function(st)
        local start = st.pos
        local np    = p(st)
        if np == nil then return nil end
        local text = st.input:sub(start, np - 1)
        local cap  = { kind = "str", value = text, start = start, finish = np - 1 }
        -- attach group name if we're inside a group()
        local names = st.names
        if names and #names > 0 then cap.group = names[#names] end
        st.captures[#st.captures + 1] = cap
        return np
    end
end

M.cap_str = M.cap

function M.cap_pos()
    return function(st)
        local cap = { kind = "pos", value = st.pos, start = st.pos, finish = st.pos - 1 }
        local names = st.names
        if names and #names > 0 then cap.group = names[#names] end
        st.captures[#st.captures + 1] = cap
        return st.pos
    end
end

function M.group(p, name)
    return function(st)
        st.names[#st.names + 1] = name
        local saved_cap_len = #st.captures
        local np = p(st)
        st.names[#st.names] = nil
        if np == nil then
            for j = #st.captures, saved_cap_len + 1, -1 do st.captures[j] = nil end
            return nil
        end
        return np
    end
end

-- ===== Forward references / grammars ==================================

function M.ref(name)
    return function(st)
        local rule = st.defs and st.defs[name]
        if rule == nil then
            error("peg.ref: unknown rule '" .. tostring(name) .. "'", 2)
        end
        return rule(st)
    end
end

function M.grammar(t)
    -- t looks like { start = <parser>, name1 = <parser>, name2 = <parser>, ... }
    -- We just remember the rules so ref() can look them up at parse time.
    if t.start == nil then
        error("peg.grammar: table must include a 'start' rule", 2)
    end
    return { _is_grammar = true, rules = t }
end

function M.match(grammar_or_parser, input)
    local g  = grammar_or_parser
    local st = {
        input    = input,
        pos      = 1,
        captures = {},
        defs     = nil,
        names    = {},
    }
    local entry
    if type(g) == "table" and g._is_grammar then
        st.defs = g.rules
        entry   = g.rules.start
    else
        entry = g
    end
    local endpos = entry(st)
    if endpos == nil then return nil, nil end
    return st.captures, endpos
end

-- ===== Common helpers ==================================================

function M.whitespace()
    -- Match one-or-more of space / tab / CR / LF / form-feed.
    return M.plus(M.set(" \t\r\n\f"))
end

function M.identifier()
    -- ASCII identifier: [A-Za-z_][A-Za-z0-9_]*
    local head = M.alt(M.range("a", "z"), M.range("A", "Z"), M.lit("_"))
    local tail = M.alt(M.range("a", "z"), M.range("A", "Z"),
                       M.range("0", "9"), M.lit("_"))
    return M.cap(M.seq(head, M.star(tail)))
end

function M.number()
    -- Signed integer / float with optional exponent.
    -- Grammar:  '-'?  ( digit+ ('.' digit*)? | '.' digit+ )  ( [eE] [+-]? digit+ )?
    local digit  = M.range("0", "9")
    local digits = M.plus(digit)
    local int_or_frac = M.alt(
        M.seq(digits, M.opt(M.seq(M.lit("."), M.star(digit)))),
        M.seq(M.lit("."), digits))
    local exp = M.seq(M.set("eE"), M.opt(M.set("+-")), digits)
    return M.cap(M.seq(M.opt(M.lit("-")), int_or_frac, M.opt(exp)))
end

function M.quoted_string()
    -- Match a JSON-ish double-quoted string. Captures the *raw* sub-string
    -- *including* the quotes; consumers can unescape as needed.
    local esc = M.seq(M.lit("\\"), M.any())
    local non_quote_byte = M.seq(M.not_(M.lit('"')), M.not_(M.lit("\\")), M.any())
    return M.cap(M.seq(M.lit('"'),
                       M.star(M.alt(esc, non_quote_byte)),
                       M.lit('"')))
end

-- ===== Spec-compatible aliases ========================================
-- The spec calls for slightly different names from the core combinators
-- above. We expose them as thin wrappers so older callers keep working.

-- rep(p, min, max?) -- bounded repetition.
function M.rep(p, min, max)
    min = min or 0
    return function(st)
        local saved_pos     = st.pos
        local saved_cap_len = #st.captures
        local count         = 0
        while true do
            if max ~= nil and count >= max then break end
            local before_pos = st.pos
            local before_cap = #st.captures
            local np = p(st)
            if np == nil or np == before_pos then
                st.pos = before_pos
                for j = #st.captures, before_cap + 1, -1 do st.captures[j] = nil end
                break
            end
            st.pos = np
            count = count + 1
        end
        if count < min then
            st.pos = saved_pos
            for j = #st.captures, saved_cap_len + 1, -1 do st.captures[j] = nil end
            return nil
        end
        return st.pos
    end
end

-- choice(...) -- alias for alt(...).
M.choice = M.alt

-- char_class("[A-Za-z_]") -- bracket-style ASCII char-class. Supports ranges
-- with -, negation with leading ^.
function M.char_class(spec)
    local negate = spec:sub(1, 1) == "^"
    if negate then spec = spec:sub(2) end
    local lut = {}
    local i = 1
    while i <= #spec do
        if i + 2 <= #spec and spec:sub(i + 1, i + 1) == "-" then
            local lo, hi = spec:byte(i), spec:byte(i + 2)
            for c = lo, hi do lut[c] = true end
            i = i + 3
        else
            lut[spec:byte(i)] = true
            i = i + 1
        end
    end
    return function(st)
        local c = st.input:byte(st.pos)
        if c == nil then return nil end
        local hit = lut[c] and true or false
        if negate then hit = not hit end
        if hit then return st.pos + 1 end
        return nil
    end
end

-- regex_class wraps Lua string.match patterns one character at a time.
function M.regex_class(pat)
    return function(st)
        local c = st.input:sub(st.pos, st.pos)
        if c == "" then return nil end
        if c:match(pat) then return st.pos + 1 end
        return nil
    end
end

-- Capture with optional transform fn(matched_text) -> value.
function M.capture(p, fn)
    return function(st)
        local start = st.pos
        local np    = p(st)
        if np == nil then return nil end
        local text = st.input:sub(start, np - 1)
        local value = fn and fn(text) or text
        local cap = { kind = "str", value = value, start = start, finish = np - 1 }
        local names = st.names
        if names and #names > 0 then cap.group = names[#names] end
        st.captures[#st.captures + 1] = cap
        return np
    end
end

-- named(name, p) -- group sub-captures of p under a name.
function M.named(name, p)
    return M.group(p, name)
end

-- ===== Grammar / parse helpers ========================================
-- The earlier grammar() takes a table { start=..., name=... }. The spec
-- requests an alternative form: grammar(rules, root?) where root names
-- the entry rule (defaulting to rules.start or rules[1]).

local _grammar_old = M.grammar

function M.grammar(rules_or_t, root)
    if root ~= nil then
        -- Spec form: rules table + explicit root name.
        local g = {}
        for k, v in pairs(rules_or_t) do g[k] = v end
        if g.start == nil then g.start = g[root] end
        if g.start == nil then
            error("peg.grammar: root rule '" .. tostring(root) .. "' not found", 2)
        end
        return _grammar_old(g)
    end
    -- Legacy / lpeg-ish form: table with .start (or [1]).
    if type(rules_or_t) == "table" and rules_or_t.start == nil and rules_or_t[1] ~= nil then
        local g = {}
        for k, v in pairs(rules_or_t) do g[k] = v end
        g.start = rules_or_t[1]
        return _grammar_old(g)
    end
    return _grammar_old(rules_or_t)
end

-- Compute (line, col) from a byte offset in `s`.
local function line_col(s, off)
    local line, col = 1, 1
    for i = 1, off - 1 do
        if s:byte(i) == 10 then line = line + 1; col = 1 else col = col + 1 end
    end
    return line, col
end

-- parse(grammar, text) -> ast, err
-- Builds an AST from the captures: top-level captures become AST nodes,
-- and named groups become a `.children` map keyed by group name.
function M.parse(g, text)
    local captures, endpos = M.match(g, text)
    if captures == nil then
        local line, col = line_col(text, 1)
        return nil, ("peg.parse: failed to match at line %d col %d"):format(line, col)
    end
    if endpos and endpos <= #text then
        local line, col = line_col(text, endpos)
        return nil, ("peg.parse: trailing input at line %d col %d (offset %d)"):format(line, col, endpos)
    end
    local ast = { type = "root", children = {}, named = {} }
    for _, c in ipairs(captures) do
        local node = { type = c.kind, value = c.value, start = c.start, finish = c.finish }
        if c.group then
            node.group = c.group
            ast.named[c.group] = ast.named[c.group] or {}
            local bucket = ast.named[c.group]
            bucket[#bucket + 1] = node
        end
        ast.children[#ast.children + 1] = node
    end
    return ast, nil
end

return M
