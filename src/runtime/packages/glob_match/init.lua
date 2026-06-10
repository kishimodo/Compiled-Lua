-- glob_match -- gitignore-style ignore-pattern matcher.
--
-- Public surface:
--   glob_match.compile(patterns)      -> matcher
--   glob_match.from_file(path)        -> matcher
--   glob_match.chain(m1, m2, ...)     -> combined matcher in priority order
--   matcher:ignored(path)             -> bool
--   matcher:match(path)               -> bool, rule_index   (false for un-ignore)
--
-- Pattern dialect (subset of gitignore(5)):
--   * Lines starting with '#' are comments; empty/whitespace-only lines are
--     skipped.
--   * A leading '/' anchors the pattern to the matcher root.
--   * A trailing '/' restricts the match to directories.
--   * Leading '!' negates the pattern (un-ignore). Negation only un-ignores
--     a previously-ignored path; it cannot resurrect a file inside a
--     directory whose parent is ignored.
--   * '*' matches any run of non-slash characters (zero or more).
--   * '?' matches a single non-slash character.
--   * '**' matches anything including slashes. '/**/' acts as "zero or more
--     path components".
--   * '[abc]' / '[!abc]' / '[a-z]' character classes (non-slash chars only).
--   * Backslash escapes the next metacharacter.
--
-- Caller is expected to normalise input paths to forward slashes and feed
-- relative paths (relative to the matcher root). Trailing slash on `path`
-- marks it as a directory.

local M = {}

local sub  = string.sub
local byte = string.byte
local find = string.find
local rep  = string.rep
local fmt  = string.format

-- ===== Pattern -> Lua pattern compilation ===============================
--
-- We convert each gitignore-style pattern to a Lua pattern. The two tricky
-- pieces are (a) '**' (which has to be translated into a multi-segment
-- wildcard) and (b) keeping '*' from crossing '/' boundaries.

local LUA_MAGIC = "().%+-*?[]^$"
local function is_magic(c)
    return LUA_MAGIC:find(c, 1, true) ~= nil
end

-- Translate the body of a [...] class to Lua's [...] syntax. The differences
-- are: gitignore uses '!' for negation (Lua uses '^'), and ']' as the first
-- char doesn't terminate the class in either dialect.
local function translate_class(s, i)
    local len = #s
    local out = "["
    local j = i + 1  -- past '['
    if j <= len and byte(s, j) == 33 then  -- '!'
        out = out .. "^"
        j = j + 1
    end
    while j <= len do
        local c = sub(s, j, j)
        if c == "]" then
            return out .. "]", j + 1
        elseif c == "%" then
            out = out .. "%%"
        elseif is_magic(c) and c ~= "-" then
            out = out .. "%" .. c
        else
            out = out .. c
        end
        j = j + 1
    end
    return nil, "unterminated character class"
end

-- Compile a single normalised pattern to:
--   { lua_pat = "...", dir_only = bool, negate = bool, anchored = bool, raw = "..." }
local function compile_one(raw)
    local pattern = raw
    local negate, anchored, dir_only = false, false, false

    if sub(pattern, 1, 1) == "!" then negate = true; pattern = sub(pattern, 2) end
    if sub(pattern, -1) == "/"   then dir_only = true; pattern = sub(pattern, 1, -2) end
    if sub(pattern, 1, 1) == "/" then anchored = true; pattern = sub(pattern, 2)
    elseif not pattern:find("/", 1, true) then
        -- Gitignore semantics: a pattern with no slash matches at any depth.
        -- We model that by NOT anchoring and letting the matcher add '(^|/)'.
        anchored = false
    else
        -- Pattern contains a slash but doesn't start with one -> implicitly
        -- anchored to the root per gitignore rules.
        anchored = true
    end

    -- Walk the pattern, building a Lua pattern. Track whether we just saw '/'
    -- to detect '/**/' as a unit.
    local out = {}
    local i, n = 1, #pattern
    while i <= n do
        local c = sub(pattern, i, i)
        if c == "\\" then
            local nx = sub(pattern, i + 1, i + 1)
            if nx == "" then return nil, "trailing backslash" end
            out[#out + 1] = is_magic(nx) and ("%" .. nx) or nx
            i = i + 2
        elseif c == "*" then
            if sub(pattern, i + 1, i + 1) == "*" then
                -- '**' -- need context: '/**/'  '/**'  '**/' or bare '**'
                local before_slash = (i == 1) or (sub(pattern, i - 1, i - 1) == "/")
                local after_slash  = (sub(pattern, i + 2, i + 2) == "/")
                if before_slash and after_slash then
                    -- '/**/' -> match zero or more full segments. Lua patterns
                    -- can't put a quantifier on a capture group, so emit a bare
                    -- '.-' span. With the preceding '/' already emitted (for the
                    -- mid-path case) '^a/.-b$' matches both 'a/b' (zero
                    -- components) and 'a/x/y/b'; a leading '**/' yields '^.-foo$'
                    -- which matches 'foo' and 'a/b/foo'. Consume the trailing '/'.
                    out[#out + 1] = ".-"
                    i = i + 3  -- skip '*', '*', '/'
                elseif after_slash then
                    out[#out + 1] = ".*/?"
                    i = i + 3
                else
                    out[#out + 1] = ".*"
                    i = i + 2
                end
            else
                out[#out + 1] = "[^/]*"
                i = i + 1
            end
        elseif c == "?" then
            out[#out + 1] = "[^/]"
            i = i + 1
        elseif c == "[" then
            local cls, ni = translate_class(pattern, i)
            if not cls then return nil, ni end
            out[#out + 1] = cls
            i = ni
        elseif is_magic(c) then
            out[#out + 1] = "%" .. c
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end

    local body = table.concat(out)
    -- Anchor the body. Lua patterns can't express "optional leading
    -- (.*/)" because `?` doesn't apply to capture groups, so we keep the
    -- pattern simple (`^body$`) and let the matcher loop feed both the
    -- full path and individual path components when the rule isn't
    -- anchored to the root.
    local lua_pat = "^" .. body .. "$"

    return {
        raw      = raw,
        lua_pat  = lua_pat,
        dir_only = dir_only,
        negate   = negate,
        anchored = anchored,
    }
end

-- ===== Matcher object ===================================================

local Matcher = {}
Matcher.__index = Matcher

local function normalise_path(p)
    -- Strip leading "./", strip any leading slash, collapse "//" runs.
    if sub(p, 1, 2) == "./" then p = sub(p, 3) end
    if sub(p, 1, 1) == "/" then p = sub(p, 2) end
    p = p:gsub("//+", "/")
    return p
end

-- Tests a single rule against the (possibly directory-marked) path.
local function rule_matches(rule, path, is_dir)
    if rule.dir_only and not is_dir then return false end
    return find(path, rule.lua_pat) ~= nil
end

function Matcher:match(path)
    -- Returns: ignored_bool, last_rule_index
    -- Iteration order follows gitignore: later rules override earlier ones.
    local is_dir = sub(path, -1) == "/"
    local clean = normalise_path(is_dir and sub(path, 1, -2) or path)

    local ignored = false
    local hit = nil

    -- Walk every rule; track the *last* match because later rules override.
    for i = 1, #self.rules do
        local r = self.rules[i]
        local matched = rule_matches(r, clean, is_dir)
        if not matched and not r.anchored then
            -- Also test the basename so "*.lua" hits "a.lua" and "dir/a.lua".
            -- Anchored rules ("/*.lua") must match the full path only, so this
            -- basename fallback is gated on the rule being un-anchored.
            local base = clean:match("([^/]+)$")
            if base and rule_matches(r, base, is_dir) then matched = true end
        end
        if not matched and not r.anchored then
            -- And each intermediate component so "node_modules" hits
            -- "x/node_modules/y" the way gitignore expects.
            for comp in clean:gmatch("[^/]+") do
                if rule_matches(r, comp, is_dir) then matched = true; break end
            end
        end
        if not matched and r.dir_only then
            -- "build/" should ignore anything under build/.
            local acc
            for comp in clean:gmatch("[^/]+") do
                acc = (acc == nil) and comp or (acc .. "/" .. comp)
                if acc == clean then break end
                if rule_matches(r, acc, true) or rule_matches(r, comp, true) then
                    matched = true; break
                end
            end
        end
        if matched then
            ignored = not r.negate
            hit = i
        end
    end

    return ignored, hit
end

function Matcher:ignored(path)
    local b = self:match(path); return b
end

-- ===== Public constructors ==============================================

function M.compile(patterns)
    if type(patterns) == "string" then
        patterns = { patterns }
    end
    local rules = {}
    for _, raw in ipairs(patterns) do
        for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
            local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" and sub(trimmed, 1, 1) ~= "#" then
                local rule, err = compile_one(trimmed)
                if not rule then return nil, "pattern '" .. trimmed .. "': " .. err end
                rules[#rules + 1] = rule
            end
        end
    end
    return setmetatable({ rules = rules }, Matcher)
end

function M.from_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local text = f:read("*a")
    f:close()
    return M.compile(text)
end

-- Chain N matchers: later matchers override earlier ones, mirroring how
-- nested .gitignore files behave (deeper dir wins).
function M.chain(...)
    local parts = { ... }
    local all = {}
    for _, m in ipairs(parts) do
        for _, r in ipairs(m.rules) do all[#all + 1] = r end
    end
    return setmetatable({ rules = all }, Matcher)
end

-- ===== Single-pattern matcher ==========================================
--
-- The legacy compile() handles full rule-set input (a multi-line .gitignore
-- block). The single-pattern API here is friendlier when a caller has
-- exactly one glob and wants both "matched" and "negated" flags returned
-- explicitly, rather than the precedence-derived "ignored" boolean.

local Single = {}
Single.__index = Single

function Single:match(path)
    -- Returns (matched, negated). matched is true when the path is touched
    -- by the rule body (regardless of negation); negated reflects whether
    -- the pattern starts with '!'.
    local is_dir = sub(path, -1) == "/"
    local clean  = is_dir and sub(path, 1, -2) or path
    -- Strip leading "./" / "/" for parity with the multi-rule matcher.
    if sub(clean, 1, 2) == "./" then clean = sub(clean, 3) end
    if sub(clean, 1, 1) == "/"  then clean = sub(clean, 2) end
    -- Try the full path first, then the basename (gitignore matches against
    -- the path AND, when un-anchored, the basename of every component).
    if rule_matches(self.rule, clean, is_dir) then
        return true, self.rule.negate
    end
    -- The basename fallback only applies to un-anchored rules; an anchored
    -- rule like "/*.lua" must match against the full path, not a deeper
    -- basename (so it must NOT match "a/b.lua").
    if not self.rule.anchored then
        local base = clean:match("([^/]+)$")
        if base and rule_matches(self.rule, base, is_dir) then
            return true, self.rule.negate
        end
    end
    -- Walk intermediate path components in case the rule matches a
    -- directory in the middle of the path (e.g. "foo" should ignore
    -- "a/foo/b"). Only relevant when the rule isn't anchored.
    if not self.rule.anchored then
        for comp in clean:gmatch("[^/]+") do
            if rule_matches(self.rule, comp, is_dir) then
                return true, self.rule.negate
            end
        end
    end
    return false, self.rule.negate
end

function Single:pattern() return self.rule.raw end

-- Module-level helpers that mirror the spec verbatim. compile(pattern) is
-- the *single-pattern* form. The multi-pattern form remains on M.compile
-- for back-compat -- detection: if input contains \n we route to the rule
-- set, otherwise to the single matcher.
local function compile_single(pattern)
    if type(pattern) ~= "string" then return nil, "pattern must be a string" end
    local rule, err = compile_one(pattern)
    if not rule then return nil, err end
    return setmetatable({ rule = rule }, Single)
end

-- Keep M.compile back-compatible for multi-line strings (the legacy shape)
-- while routing single-line input through the new Single matcher.
local _legacy_compile = M.compile
function M.compile(input)
    if type(input) == "string" and not input:find("\n") then
        return compile_single(input)
    end
    return _legacy_compile(input)
end

-- ===== Gitignore-style rule set ========================================
--
-- A wrapper that records *why* a path was ignored: the index, raw pattern,
-- and rule that decided the outcome. Late rules override early rules per
-- gitignore semantics.

local Rules = {}
Rules.__index = Rules

function Rules:match(path)
    -- Returns (ignored_bool, reason_table_or_nil).
    -- reason_table = { index = N, pattern = "...", negated = bool }
    local is_dir = sub(path, -1) == "/"
    local clean = normalise_path(is_dir and sub(path, 1, -2) or path)
    local ignored, hit_idx, hit_rule = false, nil, nil
    for i = 1, #self.rules do
        local r = self.rules[i]
        local m = rule_matches(r, clean, is_dir)
        if not m and not r.anchored then
            -- Also try the basename so rules like "*.lua" hit "a.lua".
            -- Anchored rules ("/*.lua") must match the full path only, so the
            -- basename fallback is gated on the rule being un-anchored.
            local base = clean:match("([^/]+)$")
            if base and rule_matches(r, base, is_dir) then
                m = true
            end
        end
        if not m and not r.anchored then
            -- Walk intermediate components so rules like "node_modules"
            -- hit "a/node_modules/b".
            for comp in clean:gmatch("[^/]+") do
                if rule_matches(r, comp, is_dir) then m = true; break end
            end
        end
        if not m and r.dir_only then
            -- A dir-only rule like "build/" should also ignore files
            -- *inside* the directory. Try each path prefix marked as
            -- a directory; if any matches, the descendant is ignored.
            local acc, base = "", nil
            for comp in clean:gmatch("[^/]+") do
                acc = (acc == "") and comp or (acc .. "/" .. comp)
                base = comp
                if acc == clean then break end  -- skip the leaf itself
                if rule_matches(r, acc, true) or rule_matches(r, base, true) then
                    m = true; break
                end
            end
        end
        if m then
            ignored = not r.negate
            hit_idx = i
            hit_rule = r
        end
    end
    if hit_rule then
        return ignored, { index = hit_idx, pattern = hit_rule.raw, negated = hit_rule.negate }
    end
    return false, nil
end

function Rules:size() return #self.rules end

function M.gitignore(text)
    -- text may be a string (raw .gitignore body) or array of pattern strings.
    local patterns
    if type(text) == "string" then
        patterns = { text }
    elseif type(text) == "table" then
        patterns = text
    else
        return nil, "gitignore: expected string or table"
    end
    local rules = {}
    for _, raw in ipairs(patterns) do
        for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
            local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" and sub(trimmed, 1, 1) ~= "#" then
                local rule, err = compile_one(trimmed)
                if not rule then return nil, "pattern '" .. trimmed .. "': " .. err end
                rules[#rules + 1] = rule
            end
        end
    end
    return setmetatable({ rules = rules }, Rules)
end

return M
