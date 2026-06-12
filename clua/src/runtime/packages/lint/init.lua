-- lint -- Lua linter (luacheck-lite).
--
-- Public surface:
--   lint.check(source, opts?)      -> issues
--   lint.check_file(path, opts?)   -> issues
--   lint.format(issues, style?)    -> string ("text"|"json"|"github-actions")
--   lint.lex(source)               -> tokens   (exposed; used by other tools)
--   lint.codes                     -> { [code] = { severity = , message_template = } }
--
-- An issue is { line, col, severity, code, message, name? }.
-- severity is "error" | "warning" | "info".
--
-- Options:
--   globals          extra global allowlist (table or set)
--   ignore           list of codes to suppress (or set)
--   severity_levels  override per-code severity, { [code] = "error"|... }
--   max_line_length  warn on long lines (default off)
--   require_locals   if true, every assigned identifier must be local-declared

local M = {}

-- ===== Codes ===========================================================

M.codes = {
    W001 = { severity = "warning", template = "unused local '%s'"                              },
    W002 = { severity = "warning", template = "shadowed name '%s'"                             },
    W003 = { severity = "warning", template = "unbalanced assignment: %d targets / %d values"  },
    W004 = { severity = "warning", template = "dead code after return/break"                   },
    W005 = { severity = "warning", template = "redundant assignment of '%s' to itself"         },
    W006 = { severity = "warning", template = "possible typo: '%s' (did you mean '%s'?)"       },
    W007 = { severity = "warning", template = "line too long (%d > %d)"                        },
    W008 = { severity = "warning", template = "trailing whitespace"                            },
    E001 = { severity = "error",   template = "undefined global '%s'"                          },
    E002 = { severity = "error",   template = "syntax error: %s"                               },
    E003 = { severity = "error",   template = "assignment to read-only variable '%s'"          },
    I001 = { severity = "info",    template = "long function: %d lines"                        },
    I002 = { severity = "info",    template = "magic number %s -- consider a constant"         },
}

-- ===== Default standard globals ========================================

local _STD = {
    ["_G"]=true, ["_VERSION"]=true, ["_ENV"]=true,
    assert=true, collectgarbage=true, dofile=true, error=true,
    getmetatable=true, ipairs=true, load=true, loadfile=true, loadstring=true,
    next=true, pairs=true, pcall=true, print=true, rawequal=true, rawget=true,
    rawlen=true, rawset=true, require=true, select=true, setmetatable=true,
    tonumber=true, tostring=true, type=true, unpack=true, xpcall=true,
    coroutine=true, debug=true, io=true, math=true, os=true, package=true,
    string=true, table=true, utf8=true, bit=true, bit32=true, ffi=true, jit=true,
    arg=true,
}

-- Common typo candidates -- bare keyword lookalikes.
local _TYPO_TARGETS = {
    "true", "false", "nil", "function", "local", "return", "end", "then",
    "ipairs", "pairs", "tostring", "tonumber", "string", "table", "print",
}

-- ===== Lexer ==========================================================

local _KEYWORDS = {
    ["and"]=true,["break"]=true,["do"]=true,["else"]=true,["elseif"]=true,
    ["end"]=true,["false"]=true,["for"]=true,["function"]=true,["goto"]=true,
    ["if"]=true,["in"]=true,["local"]=true,["nil"]=true,["not"]=true,
    ["or"]=true,["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,
    ["until"]=true,["while"]=true,
}

local function lex(source)
    local tokens, nt = {}, 0
    local i = 1
    local line, col = 1, 1
    local len = #source

    local function emit(kind, value, sl, sc)
        nt = nt + 1
        tokens[nt] = { kind = kind, value = value, line = sl, col = sc }
    end

    local function advance(n)
        for k = 1, n do
            local c = source:sub(i + k - 1, i + k - 1)
            if c == "\n" then line = line + 1; col = 1
            else col = col + 1 end
        end
        i = i + n
    end

    while i <= len do
        local sl, sc = line, col
        local c = source:sub(i, i)
        local b = source:byte(i)
        -- Whitespace.
        if b == 32 or b == 9 or b == 13 or b == 10 then
            advance(1)
        -- Long comment / short comment.
        elseif c == "-" and source:sub(i, i + 1) == "--" then
            advance(2)
            -- Long form: --[[ ... ]] or --[=[ ... ]=]
            if source:sub(i, i) == "[" then
                local eqs = source:match("^=*", i + 1) or ""
                if source:sub(i + 1 + #eqs, i + 1 + #eqs) == "[" then
                    local close = "]" .. eqs .. "]"
                    advance(2 + #eqs)
                    local stop = source:find(close, i, true)
                    if stop then advance(stop - i + #close)
                    else advance(len - i + 1) end
                    goto continue
                end
            end
            -- Short comment: to end of line.
            while i <= len and source:sub(i, i) ~= "\n" do advance(1) end
        -- Long string [[ ... ]] or [=[ ... ]=]
        elseif c == "[" then
            local eqs = source:match("^=*", i + 1) or ""
            if source:sub(i + 1 + #eqs, i + 1 + #eqs) == "[" then
                local close = "]" .. eqs .. "]"
                advance(2 + #eqs)
                local stop = source:find(close, i, true)
                local sv = source:sub(i, stop and (stop - 1) or len)
                emit("string", sv, sl, sc)
                if stop then advance(stop - i + #close) else advance(len - i + 1) end
            else
                emit("punct", "[", sl, sc); advance(1)
            end
        -- Strings.
        elseif c == '"' or c == "'" then
            local quote = c
            local j = i + 1
            while j <= len do
                local ch = source:sub(j, j)
                if ch == "\\" then j = j + 2
                elseif ch == quote then break
                elseif ch == "\n" then break  -- unterminated
                else j = j + 1 end
            end
            local sv = source:sub(i + 1, j - 1)
            emit("string", sv, sl, sc)
            advance(j - i + 1)
        -- Numbers.
        elseif (b >= 48 and b <= 57) or (c == "." and source:byte(i + 1) and source:byte(i + 1) >= 48 and source:byte(i + 1) <= 57) then
            local j = i
            if source:sub(j, j + 1) == "0x" or source:sub(j, j + 1) == "0X" then
                j = j + 2
                while j <= len and source:sub(j, j):match("[%x.pP+%-]") do j = j + 1 end
            else
                while j <= len and source:sub(j, j):match("[%d.eE+%-]") do
                    local ch = source:sub(j, j)
                    if (ch == "+" or ch == "-") then
                        local prev = source:sub(j - 1, j - 1)
                        if prev ~= "e" and prev ~= "E" then break end
                    end
                    j = j + 1
                end
            end
            local nv = source:sub(i, j - 1)
            emit("number", nv, sl, sc)
            advance(j - i)
        -- Identifiers / keywords.
        elseif c:match("[%a_]") then
            local j = i
            while j <= len and source:sub(j, j):match("[%w_]") do j = j + 1 end
            local v = source:sub(i, j - 1)
            if _KEYWORDS[v] then emit("keyword", v, sl, sc)
            else emit("ident", v, sl, sc) end
            advance(j - i)
        -- Punctuation / operators.
        else
            -- Multi-char operators.
            local two = source:sub(i, i + 1)
            local three = source:sub(i, i + 2)
            if three == "..." then emit("punct", "...", sl, sc); advance(3)
            elseif two == "==" or two == "~=" or two == "<=" or two == ">="
                or two == ".." or two == "::" or two == "<<" or two == ">>" or two == "//" then
                emit("punct", two, sl, sc); advance(2)
            else
                emit("punct", c, sl, sc); advance(1)
            end
        end
        ::continue::
    end
    emit("eof", "", line, col)
    return tokens
end

M.lex = lex

-- ===== Levenshtein for typo suggestions =================================

local function levenshtein(a, b)
    if a == b then return 0 end
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    if math.abs(la - lb) > 2 then return 3 end  -- cheap reject
    local prev = {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        local cur = { [0] = i }
        for j = 1, lb do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = cur
    end
    return prev[lb]
end

local function nearest_typo(name)
    local best, dist = nil, 99
    for _, cand in ipairs(_TYPO_TARGETS) do
        local d = levenshtein(name, cand)
        if d > 0 and d < dist then best, dist = cand, d end
    end
    if dist <= 2 then return best end
    return nil
end

-- ===== Lightweight scope walker =========================================
--
-- We track scopes as a stack of frames; each frame has { locals = {name=tok} }.
-- This is not a full parser -- we just detect `local NAME [, NAME]` and
-- function parameter lists, plus block-opening keywords.

local function make_set(arg)
    if not arg then return {} end
    if type(arg) ~= "table" then return {} end
    local out = {}
    if arg[1] ~= nil then
        for _, v in ipairs(arg) do out[v] = true end
    else
        for k, v in pairs(arg) do if v then out[k] = true end end
    end
    return out
end

local function check_source(src, opts)
    opts = opts or {}
    local issues, ni = {}, 0
    local globals_ok = make_set(opts.globals)
    local ignore = make_set(opts.ignore)
    local sev_override = opts.severity_levels or {}
    local max_line = opts.max_line_length

    -- Strip a leading UTF-8 BOM (EF BB BF). The real loader (luaL_loadfile) skips
    -- it, so a BOM-prefixed file compiles fine; without this, our load()-based
    -- syntax check below would choke on the BOM bytes and emit a bogus E002 on
    -- line 1. Dropping it here also keeps line-1 column numbers aligned with the
    -- source the compiler actually sees.
    if src:sub(1, 3) == "\239\187\191" then
        src = src:sub(4)
    end

    local function add(code, line, col, ...)
        if ignore[code] then return end
        local def = M.codes[code]
        local sev = sev_override[code] or (def and def.severity) or "warning"
        local msg = def and string.format(def.template, ...) or code
        ni = ni + 1
        issues[ni] = { line = line, col = col, severity = sev, code = code, message = msg }
    end

    -- Syntax check via the loader (always available, even when ffi/jit isn't).
    do
        local chunk, err = load(src, "lint", "t")
        if not chunk then
            local ln, msg = err:match(":(%d+):%s*(.+)$")
            add("E002", tonumber(ln) or 1, 1, msg or err)
        end
    end

    -- Trailing whitespace + long lines: line-oriented check, fast and easy.
    do
        local ln = 0
        for line_text in (src .. "\n"):gmatch("([^\n]*)\n") do
            ln = ln + 1
            if line_text:match("[ \t]+$") then
                add("W008", ln, 1)
            end
            if max_line and #line_text > max_line then
                add("W007", ln, max_line + 1, #line_text, max_line)
            end
        end
    end

    -- Lex.
    local tokens = lex(src)

    -- Scope stack.
    local scopes = { { locals = {}, kind = "chunk" } }
    local function push(kind) scopes[#scopes + 1] = { locals = {}, kind = kind } end
    local function pop() scopes[#scopes] = nil end
    local function declare(name, tok)
        local frame = scopes[#scopes]
        -- Shadow check: look at outer frames.
        for j = #scopes - 1, 1, -1 do
            if scopes[j].locals[name] then
                add("W002", tok.line, tok.col, name)
                break
            end
        end
        frame.locals[name] = { tok = tok, used = false, assigned_after = false }
    end
    local function resolve(name)
        for j = #scopes, 1, -1 do
            local e = scopes[j].locals[name]
            if e then return e end
        end
        return nil
    end

    -- A primitive walker over the token stream. Many constructs are ignored;
    -- we only model what's needed for the lints.
    local pos = 1
    local n = #tokens

    local function peek(off) return tokens[pos + (off or 0)] end
    local function consume() pos = pos + 1; return tokens[pos - 1] end

    local function is(tok, kind, val)
        return tok and tok.kind == kind and (val == nil or tok.value == val)
    end

    -- Track function nesting so we can flag dead code after `return`.
    local in_function_body = 0
    local after_return_in_block = false

    -- Consume a parameter list `( a, b, ... )` when positioned at the `(`,
    -- declaring each name in the current (function) scope so parameters are
    -- recognized as locals rather than misreported as undefined globals.
    -- Parameters are tagged is_param so the unused-local sweep skips them
    -- (unused arguments are common and intentional, e.g. in callbacks).
    local function declare_params()
        if not is(peek(), "punct", "(") then return end
        consume()  -- '('
        while true do
            local p = peek()
            if not p or p.kind == "eof" or is(p, "punct", ")") then break end
            if p.kind == "ident" then
                declare(p.value, p)
                local frame = scopes[#scopes]
                if frame.locals[p.value] then frame.locals[p.value].is_param = true end
                consume()
            elseif is(p, "punct", ",") or is(p, "punct", "...") then
                consume()
            else
                break
            end
        end
        if is(peek(), "punct", ")") then consume() end
    end

    while pos <= n do
        local t = tokens[pos]
        if t.kind == "eof" then break end

        -- Dead code: token following `return`/`break`/`goto` inside the same block.
        if after_return_in_block then
            -- Anything other than block-terminator means dead code.
            if not (is(t, "keyword", "end") or is(t, "keyword", "else")
                 or is(t, "keyword", "elseif") or is(t, "keyword", "until")) then
                add("W004", t.line, t.col)
                after_return_in_block = false  -- only report once per block
            else
                after_return_in_block = false
            end
        end

        if is(t, "keyword", "local") then
            consume()
            -- Optionally `local function NAME`
            if is(peek(), "keyword", "function") then
                consume()
                local name_tok = consume()
                if name_tok and name_tok.kind == "ident" then
                    declare(name_tok.value, name_tok)
                end
                -- Enter the function scope, then declare its parameters so they
                -- aren't misreported as undefined globals (LINT-PARAMS-001).
                push("function")
                in_function_body = in_function_body + 1
                declare_params()
            else
                -- Collect comma-separated names.
                local names = {}
                while true do
                    local nm = consume()
                    if nm and nm.kind == "ident" then
                        names[#names + 1] = nm
                    end
                    if not is(peek(), "punct", ",") then break end
                    consume()
                end
                -- Optional `= rhs...`
                local lhs_count = #names
                local rhs_count = 0
                local has_eq = false
                if is(peek(), "punct", "=") then
                    has_eq = true
                    consume()
                    -- Skim until line-or-block change to count RHS expressions.
                    -- Be coarse: count commas at depth 0.
                    local depth = 0
                    local saw_any = false
                    while true do
                        local p = peek()
                        if not p or p.kind == "eof" then break end
                        if p.kind == "keyword" and (
                            p.value == "local" or p.value == "end" or
                            p.value == "if" or p.value == "for" or p.value == "while" or
                            p.value == "return" or p.value == "function" or
                            p.value == "do" or p.value == "repeat" or p.value == "until" or
                            p.value == "elseif" or p.value == "else") then break end
                        if p.kind == "punct" and (p.value == "(" or p.value == "{" or p.value == "[") then
                            depth = depth + 1
                        elseif p.kind == "punct" and (p.value == ")" or p.value == "}" or p.value == "]") then
                            if depth == 0 then break end
                            depth = depth - 1
                        elseif depth == 0 and p.kind == "punct" and p.value == "," then
                            rhs_count = rhs_count + 1
                        end
                        saw_any = true
                        consume()
                    end
                    if saw_any then rhs_count = rhs_count + 1 end
                end
                if has_eq and rhs_count > 0 and lhs_count ~= rhs_count and lhs_count > 0 then
                    -- Allow last expression being a function-call to expand.
                    -- We don't track that finely; downgrade to info if lhs > rhs.
                    -- (lhs_count > 0 guards names[1] for a malformed nameless
                    -- `local = ...`; the load()-based pass then reports E002
                    -- instead of the walker throwing -- LINT-CRASH-001.)
                    add("W003", names[1].line, names[1].col, lhs_count, rhs_count)
                end
                for _, nm in ipairs(names) do declare(nm.value, nm) end
            end
        elseif is(t, "keyword", "function") then
            -- function NAME(...) / function a.b.c(...) / method function a:b(...)
            consume()
            -- Skip the name path, noting a ':' which marks a method (implicit self).
            local is_method = false
            while peek() and (peek().kind == "ident" or is(peek(), "punct", ".") or is(peek(), "punct", ":")) do
                if is(peek(), "punct", ":") then is_method = true end
                consume()
            end
            push("function")
            in_function_body = in_function_body + 1
            if is_method then
                -- method definitions get an implicit `self` parameter
                declare("self", t)
                local frame = scopes[#scopes]
                if frame.locals["self"] then frame.locals["self"].is_param = true end
            end
            declare_params()
        elseif is(t, "keyword", "do") or is(t, "keyword", "then")
            or is(t, "keyword", "repeat") then
            consume()
            push("block")
        elseif is(t, "keyword", "for") then
            consume()
            push("block")
            -- Declare loop variables.
            while true do
                local nm = peek()
                if nm and nm.kind == "ident" then
                    declare(nm.value, nm)
                    consume()
                    if is(peek(), "punct", ",") then consume() else break end
                else break end
            end
        elseif is(t, "keyword", "end") or is(t, "keyword", "until") then
            consume()
            -- Pop the innermost block/function. Before popping, finalize unused.
            local frame = scopes[#scopes]
            for name, entry in pairs(frame.locals) do
                if not entry.used and name:sub(1, 1) ~= "_" then
                    add("W001", entry.tok.line, entry.tok.col, name)
                end
            end
            if frame.kind == "function" then in_function_body = math.max(0, in_function_body - 1) end
            pop()
            after_return_in_block = false
        elseif is(t, "keyword", "else") or is(t, "keyword", "elseif") then
            consume()
            -- Re-open a sibling block: treat the if-arm as a fresh frame.
            local frame = scopes[#scopes]
            for name, entry in pairs(frame.locals) do
                if not entry.used and name:sub(1, 1) ~= "_" then
                    add("W001", entry.tok.line, entry.tok.col, name)
                end
            end
            pop()
            push("block")
            after_return_in_block = false
        elseif is(t, "keyword", "break") then
            consume()
            after_return_in_block = true
        elseif is(t, "keyword", "return") then
            -- `return` is a block's FINAL statement in valid Lua, so its trailing
            -- expression is the return value -- not dead code -- and any real
            -- statement after it is a syntax error (reported as E002), never
            -- lint-detectable dead code. So consume `return` without arming the
            -- dead-code flag and let the return-value tokens be analyzed normally
            -- (used-marking, undefined-global detection, etc.).
            consume()
            after_return_in_block = false
        elseif t.kind == "ident" then
            consume()
            local entry = resolve(t.value)
            if entry then
                entry.used = true
            else
                -- Could be a global. Skip table access prefix (a.b -> only `a` matters).
                if not _STD[t.value] and not globals_ok[t.value] then
                    -- If next token is `=` (assignment to undefined global), it's the
                    -- same warning: undefined.
                    add("E001", t.line, t.col, t.value)
                    -- Suggest a typo correction when close.
                    local guess = nearest_typo(t.value)
                    if guess then
                        add("W006", t.line, t.col, t.value, guess)
                    end
                end
            end
            -- Redundant self-assignment: `x = x` on the same line.
            if is(peek(), "punct", "=") then
                local after = tokens[pos + 1]
                local after2 = tokens[pos + 2]
                if after and after.kind == "ident" and after.value == t.value
                    and (not after2 or not (after2.kind == "punct" and (after2.value == "." or after2.value == "["))) then
                    add("W005", t.line, t.col, t.value)
                end
            end
        elseif t.kind == "number" then
            consume()
            -- Magic-number hint for non-trivial literals (only when opts.magic_numbers).
            if opts.magic_numbers then
                local v = tonumber(t.value)
                -- Flag any literal that's not 0, +/-1, and not used in a const-like context.
                if v and v ~= 0 and v ~= 1 and v ~= -1 and math.abs(v) > 1 then
                    add("I002", t.line, t.col, t.value)
                end
            end
        else
            consume()
        end
    end

    -- Final unused-locals check on the chunk frame.
    do
        local frame = scopes[1]
        if frame then
            for name, entry in pairs(frame.locals) do
                if not entry.used and name:sub(1, 1) ~= "_" then
                    add("W001", entry.tok.line, entry.tok.col, name)
                end
            end
        end
    end

    -- Stable sort: line, then col, then code.
    table.sort(issues, function(a, b)
        if a.line ~= b.line then return a.line < b.line end
        if a.col  ~= b.col  then return a.col  < b.col  end
        return a.code < b.code
    end)
    return issues
end

function M.check(source, opts)
    return check_source(source, opts)
end

function M.check_file(path, opts)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local src = f:read("*a"); f:close()
    local issues = check_source(src, opts)
    for _, iss in ipairs(issues) do iss.file = path end
    return issues
end

-- ===== Formatters ======================================================

local function fmt_text(issues)
    local buf, nb = {}, 0
    for _, iss in ipairs(issues) do
        nb = nb + 1
        buf[nb] = string.format("%s:%d:%d: %s [%s] %s",
            iss.file or "<source>", iss.line, iss.col,
            iss.severity, iss.code, iss.message)
    end
    return table.concat(buf, "\n")
end

local function fmt_json(issues)
    local ok, json = pcall(require, "json")
    if ok and json then return json.encode(issues) end
    -- Manual minimal JSON if json package missing.
    local parts, np = {}, 0
    parts[1] = "["
    np = 1
    for i, iss in ipairs(issues) do
        if i > 1 then np = np + 1; parts[np] = "," end
        np = np + 1
        parts[np] = string.format(
            '{"file":%q,"line":%d,"col":%d,"severity":%q,"code":%q,"message":%q}',
            iss.file or "", iss.line, iss.col, iss.severity, iss.code, iss.message)
    end
    np = np + 1; parts[np] = "]"
    return table.concat(parts)
end

local function fmt_github(issues)
    local buf, nb = {}, 0
    for _, iss in ipairs(issues) do
        local kind = (iss.severity == "error" and "error")
                  or (iss.severity == "warning" and "warning")
                  or "notice"
        nb = nb + 1
        buf[nb] = string.format("::%s file=%s,line=%d,col=%d::%s %s",
            kind, iss.file or "", iss.line, iss.col, iss.code, iss.message)
    end
    return table.concat(buf, "\n")
end

function M.format(issues, style)
    style = style or "text"
    if style == "json"            then return fmt_json(issues)   end
    if style == "github-actions"  then return fmt_github(issues) end
    return fmt_text(issues)
end

-- ===== Spec-style aliases ===============================================
--
-- Spec asks for lint() / lint_file() / check_all(). These thin wrappers
-- preserve the established check()/check_file() implementations.

function M.lint(source, opts)
    return M.check(source, opts)
end

function M.lint_file(path, opts)
    return M.check_file(path, opts)
end

-- Load a project-level config file (./.luavmlint.lua) when present.
local function load_project_config()
    local f = io.open(".luavmlint.lua", "rb")
    if not f then return {} end
    local src = f:read("*a"); f:close()
    local chunk = load(src, "=luavmlint", "t", {})
    if not chunk then return {} end
    local ok, cfg = pcall(chunk)
    if ok and type(cfg) == "table" then return cfg end
    return {}
end

-- check_all(paths_or_globs, opts?) -> aggregated issues across files.
-- Each item in the input list is either a literal path or a glob pattern.
function M.check_all(targets, opts)
    opts = opts or {}
    -- Merge in project config (config keys can be overridden by call-site opts).
    local project = load_project_config()
    for k, v in pairs(project) do if opts[k] == nil then opts[k] = v end end

    local files, nf = {}, 0
    local seen = {}
    local function add_file(p)
        if not seen[p] then seen[p] = true; nf = nf + 1; files[nf] = p end
    end

    local ok_glob, glob = pcall(require, "glob")
    for _, t in ipairs(targets or {}) do
        if t:find("[%*%?%[]") then
            if ok_glob and glob and type(glob.expand) == "function" then
                for _, p in ipairs(glob.expand(t) or {}) do add_file(p) end
            else
                -- Fallback: caller passed a glob but we have no expander.
                add_file(t)
            end
        else
            add_file(t)
        end
    end

    local all, na = {}, 0
    for _, path in ipairs(files) do
        local issues, err = M.check_file(path, opts)
        if not issues then
            na = na + 1
            all[na] = { file = path, line = 0, col = 0, severity = "error",
                        code = "IO001", message = "cannot read: " .. tostring(err) }
        else
            for _, iss in ipairs(issues) do na = na + 1; all[na] = iss end
        end
    end
    return all
end

return M
