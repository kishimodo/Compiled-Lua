-- path_match -- find-style boolean predicates over filesystem paths.
--
-- Public surface:
--   path_match.name(pattern)    -- basename glob, case-sensitive
--   path_match.iname(pattern)   -- basename glob, case-insensitive
--   path_match.type(kind)       -- "file" / "dir" / "symlink"
--   path_match.size(spec)       -- size comparison, e.g. ">+1M", "<1k", "=512", "+10"
--   path_match.mtime(spec)      -- mtime comparison; same form as size with seconds
--   path_match.path(pattern)    -- glob applied to the full path (slashes match)
--   path_match.depth(spec)      -- path depth comparison ("=3", ">2", "<5")
--
-- Composition:
--   path_match.and_(p1, p2, ...) -- all must hold
--   path_match.or_(p1, p2, ...)  -- any must hold
--   path_match.not_(p)
--
-- Application:
--   path_match.matches(path, pred, stat?) -> bool
--     `stat` is an optional table: { type = "file"|"dir"|"symlink", size = N, mtime = N }
--     If absent, the predicate is asked to evaluate without metadata; only
--     filename/path/depth predicates can succeed in that case.
--
-- Find-style parser:
--   path_match.compile_find(str) -> predicate
--     Accepts a subset of find(1): -type, -name, -iname, -size, -mtime,
--     -path, -ipath, -depth, plus -and, -or, -not, parentheses '(' ')',
--     and the implicit AND between successive terms.
--
-- Predicates returned by the above are plain Lua functions:
--   pred(path, stat) -> bool
-- which makes inline composition (`function(p, s) return p:match("foo") end`)
-- trivially compatible.

local M = {}

local sub  = string.sub
local find = string.find
local byte = string.byte
local upper = string.upper
local lower = string.lower

-- ===== Basic glob -> Lua pattern ========================================
--
-- Two glob flavors:
--   * name/iname operate on the basename and treat '/' as a literal.
--   * path/ipath operate on the full path; '**' is supported there.

local LUA_MAGIC = "().%+-*?[]^$"
local function is_magic(c) return LUA_MAGIC:find(c, 1, true) ~= nil end

local function glob_to_lua(pat, allow_slashes)
    local out = {}
    local i, n = 1, #pat
    while i <= n do
        local c = sub(pat, i, i)
        if c == "*" then
            if allow_slashes and sub(pat, i + 1, i + 1) == "*" then
                out[#out + 1] = ".*"; i = i + 2
            else
                out[#out + 1] = allow_slashes and "[^/]*" or "[^/]*"
                i = i + 1
            end
        elseif c == "?" then
            out[#out + 1] = "[^/]"; i = i + 1
        elseif c == "[" then
            -- pass-through, but translate '!' negation to '^'
            local j = i + 1
            local cls = "["
            if sub(pat, j, j) == "!" then cls = cls .. "^"; j = j + 1 end
            while j <= n and sub(pat, j, j) ~= "]" do
                local ch = sub(pat, j, j)
                cls = cls .. (is_magic(ch) and ch ~= "-" and ("%" .. ch) or ch)
                j = j + 1
            end
            cls = cls .. "]"
            out[#out + 1] = cls
            i = j + 1
        elseif is_magic(c) then
            out[#out + 1] = "%" .. c
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$"
end

local function basename(p)
    return p:match("([^/\\]+)[/\\]?$") or p
end

-- ===== Numeric comparison spec ==========================================
--
-- Spec syntax (loose superset of GNU find):
--   "+N"       -- value > N
--   "-N"       -- value < N
--   "N"        -- value == N (find's "exactly N units")
--   ">N", ">=N", "<N", "<=N", "=N", "!=N"
-- Suffixes for size:  k/K (1024), m/M (1024^2), g/G (1024^3), b (bytes, default)
-- Suffixes for mtime: s (sec), m (min, 60), h (3600), d (86400), w (604800)
--
-- For mtime, the "value" being compared is "now - file_mtime" -- i.e. age.

local SIZE_SUFFIX = { b = 1, c = 1, k = 1024, K = 1024,
    m = 1024 * 1024, M = 1024 * 1024,
    g = 1024 ^ 3, G = 1024 ^ 3 }

local TIME_SUFFIX = { s = 1, m = 60, h = 3600, d = 86400, w = 604800 }

local function parse_numspec(spec, suffix_table)
    local s = spec:gsub("%s+", "")
    -- Capture leading operator (default '=').
    local op = "="
    local pfx = sub(s, 1, 2)
    if pfx == ">=" or pfx == "<=" or pfx == "!=" then
        op = pfx; s = sub(s, 3)
    else
        local c = sub(s, 1, 1)
        if c == ">" or c == "<" or c == "=" then op = c; s = sub(s, 2)
        elseif c == "+" then op = ">"; s = sub(s, 2)
        elseif c == "-" then op = "<"; s = sub(s, 2)
        end
    end

    -- Split number + optional suffix.
    local body, suf = s:match("^([%d%.]+)(.-)$")
    if not body then return nil, "bad numeric spec: " .. spec end
    local n = tonumber(body)
    if not n then return nil, "bad number: " .. body end
    if suf ~= "" then
        local mult = suffix_table and suffix_table[suf]
        if not mult then return nil, "bad suffix: " .. suf end
        n = n * mult
    end
    return op, n
end

local function compare_num(value, op, n)
    if op == "="  then return value == n end
    if op == "!=" then return value ~= n end
    if op == ">"  then return value >  n end
    if op == ">=" then return value >= n end
    if op == "<"  then return value <  n end
    if op == "<=" then return value <= n end
    return false
end

-- ===== Built-in predicate factories =====================================

function M.name(pattern)
    local lp = glob_to_lua(pattern, false)
    return function(path) return find(basename(path), lp) ~= nil end
end

function M.iname(pattern)
    local lp = glob_to_lua(lower(pattern), false)
    return function(path) return find(lower(basename(path)), lp) ~= nil end
end

function M.path(pattern)
    local lp = glob_to_lua(pattern, true)
    return function(path) return find(path, lp) ~= nil end
end

function M.ipath(pattern)
    local lp = glob_to_lua(lower(pattern), true)
    return function(path) return find(lower(path), lp) ~= nil end
end

function M.type(kind)
    -- Allow GNU-find short letters too: f, d, l.
    local m = { f = "file", d = "dir", l = "symlink",
                file = "file", dir = "dir", symlink = "symlink" }
    local want = m[kind]
    if not want then error("path_match.type: unknown kind '" .. tostring(kind) .. "'") end
    return function(_, stat) return stat and stat.type == want end
end

function M.size(spec)
    local op, n = parse_numspec(spec, SIZE_SUFFIX)
    if not op then error("path_match.size: " .. n) end
    return function(_, stat) return stat and stat.size and compare_num(stat.size, op, n) end
end

function M.mtime(spec)
    -- mtime predicate compares *age* (now - stat.mtime). Captures `now` at
    -- match time so a long-lived predicate evaluates relative to "now-ish".
    local op, n = parse_numspec(spec, TIME_SUFFIX)
    if not op then error("path_match.mtime: " .. n) end
    return function(_, stat)
        if not stat or not stat.mtime then return false end
        local age = os.time() - stat.mtime
        return compare_num(age, op, n)
    end
end

function M.depth(spec)
    -- Path depth = count of '/' separators (after normalisation). A bare
    -- filename has depth 0.
    local op, n
    if type(spec) == "number" then op, n = "=", spec
    else op, n = parse_numspec(tostring(spec), nil) end
    if not op then error("path_match.depth: " .. tostring(n)) end
    return function(path)
        local d = 0
        for _ in path:gmatch("[/\\]") do d = d + 1 end
        return compare_num(d, op, n)
    end
end

-- ===== Boolean combinators ==============================================

function M.and_(...)
    -- Build the parts table explicitly via select() to avoid emitting
    -- OP_SETLIST-with-varargs, which some hosts can't JIT-compile.
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = (select(i, ...)) end
    return function(path, stat)
        for i = 1, n do if not parts[i](path, stat) then return false end end
        return true
    end
end

function M.or_(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = (select(i, ...)) end
    return function(path, stat)
        for i = 1, n do if parts[i](path, stat) then return true end end
        return false
    end
end

function M.not_(pred)
    return function(path, stat) return not pred(path, stat) end
end

function M.matches(path, pred, stat)
    return pred(path, stat) == true
end

-- ===== Find-style string compiler =======================================
--
-- Lexer turns the source into tokens:
--   { kind = "flag",   value = "-type" }
--   { kind = "string", value = "..." }
--   { kind = "lparen" } / { kind = "rparen" }
-- Whitespace separates; quotes group; backslash escapes inside quotes.

local function find_lex(s)
    local toks = {}
    local i, n = 1, #s
    while i <= n do
        local c = sub(s, i, i)
        if c == " " or c == "\t" or c == "\n" then
            i = i + 1
        elseif c == "(" then
            toks[#toks + 1] = { kind = "lparen" }; i = i + 1
        elseif c == ")" then
            toks[#toks + 1] = { kind = "rparen" }; i = i + 1
        elseif c == "'" or c == '"' then
            local q = c; i = i + 1
            local s0 = i
            local parts, np = nil, 0
            while i <= n and sub(s, i, i) ~= q do
                if sub(s, i, i) == "\\" and i < n then
                    parts = parts or {}
                    if i > s0 then np = np + 1; parts[np] = sub(s, s0, i - 1) end
                    np = np + 1; parts[np] = sub(s, i + 1, i + 1)
                    i = i + 2
                    s0 = i
                else
                    i = i + 1
                end
            end
            if i > n then return nil, "unterminated string" end
            local val
            if parts then
                if i > s0 then np = np + 1; parts[np] = sub(s, s0, i - 1) end
                val = table.concat(parts)
            else
                val = sub(s, s0, i - 1)
            end
            toks[#toks + 1] = { kind = "string", value = val }
            i = i + 1
        elseif c == "-" then
            -- Could be a flag like -name or a numeric arg like -7. Flags start
            -- with -<letter>.
            local nx = sub(s, i + 1, i + 1)
            if nx:match("%a") then
                local j = i + 1
                while j <= n do
                    local ch = sub(s, j, j)
                    if ch:match("[%w_]") then j = j + 1 else break end
                end
                toks[#toks + 1] = { kind = "flag", value = sub(s, i, j - 1) }
                i = j
            else
                -- Treat as start of a bareword/number.
                local j = i
                while j <= n do
                    local ch = sub(s, j, j)
                    if ch == " " or ch == "\t" or ch == "\n" or ch == "(" or ch == ")" then break end
                    j = j + 1
                end
                toks[#toks + 1] = { kind = "string", value = sub(s, i, j - 1) }
                i = j
            end
        else
            -- Bareword
            local j = i
            while j <= n do
                local ch = sub(s, j, j)
                if ch == " " or ch == "\t" or ch == "\n" or ch == "(" or ch == ")" then break end
                j = j + 1
            end
            toks[#toks + 1] = { kind = "string", value = sub(s, i, j - 1) }
            i = j
        end
    end
    return toks
end

-- Recursive-descent parser for the find subset.
-- Grammar:
--   expr     := or_expr
--   or_expr  := and_expr ( '-or' and_expr )*
--   and_expr := unary    ( ('-and')? unary )*
--   unary    := '-not' unary | atom
--   atom     := '(' expr ')' | predicate
--   predicate := flag arg?

local FLAG_PRED = {
    ["-name"]  = function(arg) return M.name(arg) end,
    ["-iname"] = function(arg) return M.iname(arg) end,
    ["-path"]  = function(arg) return M.path(arg) end,
    ["-ipath"] = function(arg) return M.ipath(arg) end,
    ["-type"]  = function(arg) return M.type(arg) end,
    ["-size"]  = function(arg) return M.size(arg) end,
    ["-mtime"] = function(arg) return M.mtime(arg) end,
    ["-depth"] = function(arg) return M.depth(arg) end,
}

local FLAG_ARGLESS = {
    ["-true"]  = function() return function() return true  end end,
    ["-false"] = function() return function() return false end end,
}

local function parse_find(toks)
    local pos = 1
    local function peek() return toks[pos] end
    local function eat() local t = toks[pos]; pos = pos + 1; return t end

    local parse_expr  -- forward

    local function parse_atom()
        local t = peek()
        if not t then error("path_match: unexpected end of expression") end
        if t.kind == "lparen" then
            eat()
            local e = parse_expr()
            local r = eat()
            if not r or r.kind ~= "rparen" then error("path_match: expected ')'") end
            return e
        elseif t.kind == "flag" then
            eat()
            local factory = FLAG_PRED[t.value]
            if factory then
                local arg = eat()
                if not arg or arg.kind ~= "string" then
                    error("path_match: " .. t.value .. " requires an argument")
                end
                return factory(arg.value)
            end
            local argless = FLAG_ARGLESS[t.value]
            if argless then return argless() end
            error("path_match: unknown flag '" .. t.value .. "'")
        else
            error("path_match: unexpected token '" .. tostring(t.value) .. "'")
        end
    end

    local function parse_unary()
        local t = peek()
        if t and t.kind == "flag" and t.value == "-not" then
            eat(); return M.not_(parse_unary())
        end
        if t and t.kind == "flag" and t.value == "!" then
            eat(); return M.not_(parse_unary())
        end
        return parse_atom()
    end

    local function parse_and()
        local lhs = parse_unary()
        while true do
            local t = peek()
            if not t then break end
            if t.kind == "flag" and t.value == "-and" then
                eat()
                lhs = M.and_(lhs, parse_unary())
            elseif t.kind == "flag" and t.value == "-or" then
                break
            elseif t.kind == "rparen" then
                break
            else
                -- Implicit AND between adjacent atoms.
                lhs = M.and_(lhs, parse_unary())
            end
        end
        return lhs
    end

    parse_expr = function()
        local lhs = parse_and()
        while true do
            local t = peek()
            if t and t.kind == "flag" and t.value == "-or" then
                eat()
                lhs = M.or_(lhs, parse_and())
            else
                break
            end
        end
        return lhs
    end

    return parse_expr()
end

function M.compile_find(src)
    if type(src) ~= "string" then return nil, "source must be a string" end
    local toks, err = find_lex(src)
    if not toks then return nil, err end
    if #toks == 0 then return function() return true end end
    local ok, pred_or_err = pcall(parse_find, toks)
    if not ok then return nil, tostring(pred_or_err) end
    return pred_or_err
end

-- ===== High-level pred.* namespace ======================================
--
-- The legacy API exposes name/iname/size/mtime etc. directly on M. The
-- caller-facing spec wants a friendlier `pred.size_above(n)` /
-- `pred.mtime_after(t)` shape that takes plain numbers and returns the
-- same `path, stat -> bool` predicates. This is just a thin layer.

local pred = {}

function pred.name(pattern)
    return M.name(pattern)
end

function pred.path(pattern)
    return M.path(pattern)
end

function pred.ext(ext_or_list)
    -- Accept "lua" / ".lua" / { "lua", "txt" } / { ".lua", ".txt" }
    local set = {}
    local function add(e)
        if e == nil then return end
        if sub(e, 1, 1) == "." then e = sub(e, 2) end
        set[lower(e)] = true
    end
    if type(ext_or_list) == "string" then
        add(ext_or_list)
    elseif type(ext_or_list) == "table" then
        for _, e in ipairs(ext_or_list) do add(e) end
    else
        error("pred.ext: expected string or list")
    end
    return function(path)
        local e = path:match("%.([^./\\]+)$")
        return e ~= nil and set[lower(e)] == true
    end
end

function pred.type(kind)
    return M.type(kind)
end

function pred.size_above(n)
    return function(_, stat)
        return stat ~= nil and stat.size ~= nil and stat.size > n
    end
end

function pred.size_below(n)
    return function(_, stat)
        return stat ~= nil and stat.size ~= nil and stat.size < n
    end
end

function pred.mtime_after(t)
    return function(_, stat)
        return stat ~= nil and stat.mtime ~= nil and stat.mtime > t
    end
end

function pred.mtime_before(t)
    return function(_, stat)
        return stat ~= nil and stat.mtime ~= nil and stat.mtime < t
    end
end

function pred.exec()
    -- A stat may carry a `mode` (POSIX-style) or an `executable` boolean.
    -- We accept either signal. On Windows the caller is expected to fill
    -- in `executable` based on file extension (.exe/.bat/.cmd/.ps1) since
    -- there is no Unix x-bit; this predicate stays signal-agnostic.
    return function(_, stat)
        if stat == nil then return false end
        if stat.executable == true then return true end
        if type(stat.mode) == "number" then
            -- Any of the three x bits.
            return (stat.mode & 0x49) ~= 0
        end
        return false
    end
end

function pred.readable()
    return function(_, stat)
        if stat == nil then return false end
        if stat.readable == true then return true end
        if type(stat.mode) == "number" then
            return (stat.mode & 0x124) ~= 0
        end
        -- Default: if we have a stat record at all the file is at least
        -- statable, which implies readable in most environments.
        return true
    end
end

-- Combinators.
function pred.and_(...) return M.and_(...) end
function pred.or_(...)  return M.or_(...)  end
function pred.not_(p)   return M.not_(p)   end
function pred.any(...)  return M.or_(...)  end
function pred.all(...)  return M.and_(...) end

M.pred = pred

-- ===== find(root, predicate, opts?) =====================================
--
-- Walks a directory tree and yields paths for which the predicate holds.
-- The fs package is preferred; we soft-require it so this module loads
-- standalone. opts:
--   { max_depth = N, follow_symlinks = bool, stat = fn(path) -> stat,
--     iter = bool (when true, returns a stateful iterator rather than a list) }
--
-- The default `stat` plumbs through fs.stat if present, otherwise returns
-- a minimal table with just `path`. The walker uses fs.readdir or
-- io.popen("dir") fallback (Windows only). On bare Lua with no fs and no
-- popen, this returns an empty list.

local function _try_require(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    return nil
end

local function default_stat(path, fs)
    if fs and fs.stat then
        local ok, st = pcall(fs.stat, path)
        if ok and st then
            -- Normalise into the shape this module's predicates expect.
            return {
                type = st.type or st.kind,
                size = st.size,
                mtime = st.mtime,
                mode = st.mode,
                executable = st.executable,
                readable = st.readable,
                path = path,
            }
        end
    end
    return { path = path }
end

local function listdir(path, fs)
    if fs and fs.readdir then
        local ok, entries = pcall(fs.readdir, path)
        if ok and type(entries) == "table" then return entries end
    end
    -- Windows fallback via cmd.exe `dir` -- best-effort.
    local cmd = 'dir /B "' .. path:gsub('"', '') .. '" 2>nul'
    local f = io.popen(cmd, "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end

local function is_dir(stat)
    return stat and stat.type == "dir"
end

local function join(a, b)
    if a == "" or a == nil then return b end
    local last = sub(a, -1)
    if last == "/" or last == "\\" then return a .. b end
    return a .. "/" .. b
end

function M.find(root, predicate, opts)
    opts = opts or {}
    local max_depth = opts.max_depth or math.huge
    local fs = opts.fs or _try_require("fs")
    local stat_fn = opts.stat or function(p) return default_stat(p, fs) end

    local results = {}

    local function visit(path, depth)
        local st = stat_fn(path)
        if predicate(path, st) then results[#results + 1] = path end
        if depth >= max_depth then return end
        if is_dir(st) or (st and st.type == nil) then
            -- Try descending regardless of unknown type; listdir returns
            -- empty for plain files so this is safe.
            local entries = listdir(path, fs)
            for _, name in ipairs(entries) do
                if name ~= "." and name ~= ".." then
                    visit(join(path, name), depth + 1)
                end
            end
        end
    end

    visit(root, 0)
    if opts.iter then
        local i = 0
        return function()
            i = i + 1
            return results[i]
        end
    end
    return results
end

return M
