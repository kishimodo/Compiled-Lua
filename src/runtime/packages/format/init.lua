-- format -- Lua source formatter.
--
-- Public surface:
--   format.format(source, opts?)         -> formatted source
--   format.format_file(path, opts?)      -> ok, err   writes formatted file in place
--   format.diff(source, opts?)           -> unified diff between input and output
--
-- Options:
--   indent             "    "   indentation string
--   quote              '"'      preferred string quote
--   max_table_line     80       inline tables under this width
--   trailing_comma     true     add trailing comma in multi-line tables
--   align_assignments  false    align '=' in consecutive assignments
--   space_inside_brackets false  add spaces inside ( ) and [ ]
--   max_blank_lines    1        collapse runs of blank lines
--
-- The formatter is token-based: it tokenizes, classifies each token, and
-- re-emits with consistent spacing/indenting. It is idempotent on its own
-- output by design (no AST rewriting, just whitespace normalization).

local M = {}

-- ===== Tokenizer (lossless: keeps comments/whitespace) =================

local _KEYWORDS = {
    ["and"]=true,["break"]=true,["do"]=true,["else"]=true,["elseif"]=true,
    ["end"]=true,["false"]=true,["for"]=true,["function"]=true,["goto"]=true,
    ["if"]=true,["in"]=true,["local"]=true,["nil"]=true,["not"]=true,
    ["or"]=true,["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,
    ["until"]=true,["while"]=true,
}

local function tokenize(src)
    local out, no = {}, 0
    local i = 1
    local line = 1
    local len = #src

    local function emit(kind, value, sl)
        no = no + 1
        out[no] = { kind = kind, value = value, line = sl }
    end

    local function count_newlines(s)
        local n = 0
        for _ in s:gmatch("\n") do n = n + 1 end
        return n
    end

    while i <= len do
        local sl = line
        local c = src:sub(i, i)
        local b = src:byte(i)

        if b == 32 or b == 9 or b == 10 or b == 13 then
            local j = i
            while j <= len do
                local bb = src:byte(j)
                if bb == 32 or bb == 9 or bb == 10 or bb == 13 then j = j + 1 else break end
            end
            local v = src:sub(i, j - 1)
            line = line + count_newlines(v)
            emit("ws", v, sl)
            i = j
        elseif c == "-" and src:sub(i, i + 1) == "--" then
            -- Comment.
            local j = i + 2
            if src:sub(j, j) == "[" then
                local eqs = src:match("^=*", j + 1) or ""
                if src:sub(j + 1 + #eqs, j + 1 + #eqs) == "[" then
                    local close = "]" .. eqs .. "]"
                    local stop = src:find(close, j + 2 + #eqs, true)
                    if stop then j = stop + #close - 1 else j = len end
                    local v = src:sub(i, j)
                    line = line + count_newlines(v)
                    emit("comment_long", v, sl)
                    i = j + 1
                    goto continue
                end
            end
            while j <= len and src:sub(j, j) ~= "\n" do j = j + 1 end
            emit("comment_line", src:sub(i, j - 1), sl)
            i = j
        elseif c == "[" then
            local eqs = src:match("^=*", i + 1) or ""
            if src:sub(i + 1 + #eqs, i + 1 + #eqs) == "[" then
                local close = "]" .. eqs .. "]"
                local stop = src:find(close, i + 2 + #eqs, true)
                local endpos = stop and (stop + #close - 1) or len
                local v = src:sub(i, endpos)
                line = line + count_newlines(v)
                emit("string_long", v, sl)
                i = endpos + 1
            else
                emit("punct", "[", sl); i = i + 1
            end
        elseif c == '"' or c == "'" then
            local quote = c
            local j = i + 1
            while j <= len do
                local ch = src:sub(j, j)
                if ch == "\\" then j = j + 2
                elseif ch == quote then j = j + 1; break
                elseif ch == "\n" then break
                else j = j + 1 end
            end
            emit("string", src:sub(i, j - 1), sl)
            i = j
        elseif (b >= 48 and b <= 57) or (c == "." and src:byte(i + 1) and src:byte(i + 1) >= 48 and src:byte(i + 1) <= 57) then
            local j = i
            if src:sub(j, j + 1) == "0x" or src:sub(j, j + 1) == "0X" then
                j = j + 2
                while j <= len and src:sub(j, j):match("[%x.pP+%-]") do
                    local ch = src:sub(j, j)
                    if (ch == "+" or ch == "-") then
                        local prev = src:sub(j - 1, j - 1)
                        if prev ~= "p" and prev ~= "P" then break end
                    end
                    j = j + 1
                end
            else
                while j <= len and src:sub(j, j):match("[%d.eE+%-]") do
                    local ch = src:sub(j, j)
                    if (ch == "+" or ch == "-") then
                        local prev = src:sub(j - 1, j - 1)
                        if prev ~= "e" and prev ~= "E" then break end
                    end
                    j = j + 1
                end
            end
            emit("number", src:sub(i, j - 1), sl)
            i = j
        elseif c:match("[%a_]") then
            local j = i
            while j <= len and src:sub(j, j):match("[%w_]") do j = j + 1 end
            local v = src:sub(i, j - 1)
            emit(_KEYWORDS[v] and "keyword" or "ident", v, sl)
            i = j
        else
            local two = src:sub(i, i + 1)
            local three = src:sub(i, i + 2)
            if three == "..." then emit("punct", "...", sl); i = i + 3
            elseif two == "==" or two == "~=" or two == "<=" or two == ">="
                or two == ".." or two == "::" or two == "<<" or two == ">>" or two == "//" then
                emit("punct", two, sl); i = i + 2
            else
                emit("punct", c, sl); i = i + 1
            end
        end
        ::continue::
    end
    return out
end

-- ===== Re-quote strings using preferred quote ===========================

local function requote(literal, want)
    if #literal < 2 then return literal end
    local first = literal:sub(1, 1)
    if first ~= "'" and first ~= '"' then return literal end
    local inner = literal:sub(2, -2)
    if first == want then return literal end
    -- Switching quotes: must escape any occurrence of `want` inside, and we
    -- can unescape the existing quote since it's no longer the delimiter.
    -- Be conservative: bail out if the inner uses tricky escapes.
    local needs_escape = false
    local i = 1
    while i <= #inner do
        local c = inner:sub(i, i)
        if c == "\\" then
            i = i + 2  -- skip next char
        elseif c == want then
            needs_escape = true
            i = i + 1
        else
            i = i + 1
        end
    end
    if needs_escape then return literal end  -- leave alone rather than mis-escape
    -- Unescape any \first since it's no longer needed.
    local rebuilt = inner:gsub("\\" .. first, first)
    return want .. rebuilt .. want
end

-- ===== Spacing rules ====================================================
--
-- A "code" token is anything that isn't ws/comment. The formatter walks code
-- tokens deciding the gap between adjacent tokens (none, space, or newline+indent).

local _BINOP = {
    ["+"]=true,["-"]=true,["*"]=true,["/"]=true,["%"]=true,["^"]=true,
    [".."]=true,["=="]=true,["~="]=true,["<="]=true,[">="]=true,
    ["<"]=true,[">"]=true,["="]=true,
    ["//"]=true,["<<"]=true,[">>"]=true,["&"]=true,["|"]=true,["~"]=true,
}

local _KEYWORD_BINOP = {
    ["and"]=true,["or"]=true,
}

local function is_binop(tok)
    if not tok then return false end
    if tok.kind == "punct" and _BINOP[tok.value] then return true end
    if tok.kind == "keyword" and _KEYWORD_BINOP[tok.value] then return true end
    return false
end

-- Disambiguate unary minus / colon / dot from operators.
local function space_between(prev, cur)
    if not prev then return "" end
    local pv, cv = prev.value, cur.value
    local pk, ck = prev.kind, cur.kind

    -- Hard "no space":
    if pk == "punct" and (pv == "(" or pv == "[" or pv == "{") then return "" end
    if ck == "punct" and (cv == ")" or cv == "]" or cv == "}" or cv == "," or cv == ";") then return "" end
    if pk == "punct" and (pv == "." or pv == ":") then return "" end
    if ck == "punct" and (cv == "." or cv == ":") then return "" end
    -- Function call paren: no space between callee and '('.
    if ck == "punct" and cv == "(" and (pk == "ident" or pk == "string" or pk == "string_long"
        or (pk == "punct" and (pv == ")" or pv == "]" or pv == "}"))) then return "" end
    if ck == "punct" and cv == "[" and (pk == "ident"
        or (pk == "punct" and (pv == ")" or pv == "]" or pv == "}"))) then return "" end
    -- String/table call form: foo"bar", foo{...} -> no space.
    if (ck == "string" or ck == "string_long" or (ck == "punct" and cv == "{"))
        and (pk == "ident" or (pk == "punct" and (pv == ")" or pv == "]" or pv == "}"))) then
        return ""
    end
    -- After ',' or ';', single space.
    if pk == "punct" and (pv == "," or pv == ";") then return " " end
    -- Binary operators get spaces on both sides.
    if is_binop(prev) or is_binop(cur) then return " " end
    -- Keywords nearly always want spacing.
    if pk == "keyword" or ck == "keyword" then
        -- but `function(` should have no space (anonymous function)
        if pk == "keyword" and pv == "function" and ck == "punct" and cv == "(" then return "" end
        return " "
    end
    -- Two punct symbols touching: keep tight.
    if pk == "punct" and ck == "punct" then return "" end
    -- Default: separator.
    return " "
end

-- ===== Render ==========================================================

local function normalize_opts(opts)
    opts = opts or {}
    return {
        indent            = opts.indent            or "    ",
        quote             = opts.quote             or '"',
        max_table_line    = opts.max_table_line    or 80,
        trailing_comma    = opts.trailing_comma ~= false,
        align_assignments = opts.align_assignments or false,
        max_blank_lines   = opts.max_blank_lines   or 1,
    }
end

-- Drop ws tokens but remember structural newlines: we collapse runs of
-- blank lines, then re-emit indentation ourselves.
local function strip_ws(tokens, opts)
    local out, no = {}, 0
    local pending_blanks = 0
    local pending_break = false
    for _, t in ipairs(tokens) do
        if t.kind == "ws" then
            -- Count blank lines (consecutive newlines).
            local nl = 0
            for _ in t.value:gmatch("\n") do nl = nl + 1 end
            if nl >= 1 then pending_break = true end   -- a newline = a statement break hint
            if nl >= 2 then
                pending_blanks = math.max(pending_blanks, math.min(nl - 1, opts.max_blank_lines))
            end
        else
            if pending_blanks > 0 and no > 0 then
                for _ = 1, pending_blanks do
                    no = no + 1; out[no] = { kind = "blank", value = "", line = t.line }
                end
                pending_blanks = 0
            end
            -- Remember that the source put a newline before this code token, so
            -- render() can keep separate top-level statements on separate lines.
            if pending_break and no > 0 then t.soft_break = true end
            pending_break = false
            no = no + 1; out[no] = t
        end
    end
    return out
end

-- Indent-change rules: which tokens open/close blocks.
local function indent_delta(tok, next_tok)
    if tok.kind == "keyword" then
        local v = tok.value
        if v == "do" or v == "then" or v == "function" or v == "repeat" then return 1 end
        if v == "else" then return 0 end  -- handled by dedent on the line itself
        if v == "end" or v == "until" then return -1 end
    end
    if tok.kind == "punct" then
        if tok.value == "{" then return 1 end
        if tok.value == "}" then return -1 end
        if tok.value == "(" then return 1 end
        if tok.value == ")" then return -1 end
    end
    return 0
end

-- Walk code tokens and produce a sequence of (token, leading_gap_kind):
-- where leading_gap_kind is "none", "space", "newline".
local function render(tokens, opts)
    local lines, nl = {}, 0
    local cur, nc = {}, 0
    local indent_level = 0
    local paren_depth = 0  -- inside (...) we don't add newlines automatically
    local nest_depth = 0   -- depth of any ( [ { -- soft breaks only at top level

    local function flush_line()
        if nc == 0 then nl = nl + 1; lines[nl] = ""; return end
        nl = nl + 1
        lines[nl] = opts.indent:rep(indent_level) .. table.concat(cur)
        cur, nc = {}, 0
    end

    -- We'll iterate twice: first pass produces a sequence of code tokens with
    -- "logical" newline markers based on Lua's statement boundaries.

    -- Strategy: a code token starts a new line if:
    --   - previous token is a statement terminator (return-args end, end of `local x = y`),
    --   - OR previous token is `then`, `do`, `else`, `repeat`, `function (body)`, `{`,
    --   - OR previous token is `;`,
    --   - OR a long comment.

    local function starts_new_line(prev, cur_t)
        if not prev then return false end
        if prev.kind == "blank" then return true end
        if prev.kind == "comment_line" then return true end
        if prev.kind == "keyword" then
            local v = prev.value
            if v == "do" or v == "then" or v == "else" or v == "repeat" then return true end
        end
        if prev.kind == "punct" and prev.value == ";" then return true end
        -- A closing `end`/`until` ends a block; the next code token usually starts a new line.
        if prev.kind == "keyword" and (prev.value == "end" or prev.value == "until") then
            -- Don't break the line if the next token continues an expression:
            -- e.g. `(function() end)()` -- the `)` should stay tight.
            if cur_t.kind == "punct" and (cur_t.value == ")" or cur_t.value == ","
                or cur_t.value == "]" or cur_t.value == "}" or cur_t.value == ";") then
                return false
            end
            return true
        end
        -- A `{` typically opens a table on the same line, but the contents go on
        -- a new line if the table is long. We let the second pass decide.
        return false
    end

    -- Track: at each `{`, remember the start position so a second pass can decide
    -- inline vs multi-line. For now, single-line emit, and a post-pass splits
    -- over-long lines containing table literals.

    for idx, t in ipairs(tokens) do
        if t.kind == "blank" then
            -- Close any pending content line FIRST (flush_line emits a blank only
            -- when the buffer is empty), then emit exactly one blank line. The old
            -- single flush_line() flushed the pending statement and dropped the
            -- blank entirely, so `max_blank_lines >= 1` collapsed runs to zero.
            if nc > 0 then flush_line() end
            nl = nl + 1; lines[nl] = ""
            goto continue
        end

        -- Dedent before emitting `end`/`until`/`else`/`elseif`/`}`/`)`.
        local pre_delta = 0
        if t.kind == "keyword" and (t.value == "end" or t.value == "until"
            or t.value == "else" or t.value == "elseif") then
            pre_delta = -1
        elseif t.kind == "punct" and (t.value == "}" or t.value == ")") then
            pre_delta = -1
        end

        -- Decide if we start a new line.
        local prev_code
        for j = idx - 1, 1, -1 do
            local pt = tokens[j]
            if pt.kind ~= "blank" then prev_code = pt; break end
        end

        -- Break the line when the structural heuristic says so, OR when the
        -- ORIGINAL source had a newline here at the TOP level (nest_depth == 0):
        -- that preserves separate statements ("local a=1\nlocal b=2") instead of
        -- merging them onto one physical line, while leaving expressions and
        -- table/argument layout (inside brackets) to the formatter.
        if nc > 0 and ((t.soft_break and nest_depth == 0) or starts_new_line(prev_code, t)) then
            flush_line()
        end

        if pre_delta < 0 and nc == 0 then
            indent_level = math.max(0, indent_level + pre_delta)
        elseif pre_delta < 0 then
            -- mid-line dedent: ignore; matters only at line start
        end

        -- Build the spacing relative to the previous *emitted* token on this line.
        local prev_on_line
        for j = nc, 1, -1 do
            if cur[j] and cur[j] ~= "" then prev_on_line = cur[j]; break end
        end
        -- We tracked the prior token object for spacing decisions:
        local sp = " "
        if nc == 0 then
            sp = ""  -- indentation handled by flush_line
        else
            -- Find the previous original token (skip blanks/comments).
            local prev_code_for_space
            for j = idx - 1, 1, -1 do
                local pt = tokens[j]
                if pt.kind == "blank" then break end
                if pt.kind ~= "ws" then prev_code_for_space = pt; break end
            end
            if prev_code_for_space then
                sp = space_between(prev_code_for_space, t)
            else
                sp = ""
            end
        end

        local emit_text
        if t.kind == "string" then
            emit_text = requote(t.value, opts.quote)
        else
            emit_text = t.value
        end

        if sp ~= "" then nc = nc + 1; cur[nc] = sp end
        nc = nc + 1; cur[nc] = emit_text

        -- Post-emit indent change for openers.
        local post_delta = indent_delta(t, tokens[idx + 1])
        -- Only count blocks that span lines; punctuation paren depth doesn't change indent
        -- unless we put their contents on new lines (multi-line table handled later).
        if t.kind == "keyword" then
            if post_delta > 0 then indent_level = indent_level + post_delta end
        end
        if t.kind == "punct" and t.value == "(" then paren_depth = paren_depth + 1 end
        if t.kind == "punct" and t.value == ")" then paren_depth = math.max(0, paren_depth - 1) end
        if t.kind == "punct" and (t.value == "(" or t.value == "[" or t.value == "{") then
            nest_depth = nest_depth + 1
        elseif t.kind == "punct" and (t.value == ")" or t.value == "]" or t.value == "}") then
            nest_depth = math.max(0, nest_depth - 1)
        end

        -- Comments at end-of-line: flush after.
        if t.kind == "comment_line" then flush_line() end

        ::continue::
    end
    flush_line()

    return lines
end

-- ===== Multi-line table splitter ========================================
--
-- After the initial render, split lines containing `{ ... }` table literals
-- that exceed max_table_line into a multi-line form with trailing commas.

local function split_long_tables(lines, opts)
    local out, no = {}, 0
    for _, line in ipairs(lines) do
        if #line <= opts.max_table_line or not line:find("{", 1, true) then
            no = no + 1; out[no] = line
        else
            -- Find the outermost `{ ... }` and break its top-level commas.
            local indent_match = line:match("^(%s*)") or ""
            local open = line:find("{", 1, true)
            local depth = 0
            local close
            for i = open, #line do
                local c = line:sub(i, i)
                if c == "{" then depth = depth + 1
                elseif c == "}" then
                    depth = depth - 1
                    if depth == 0 then close = i; break end
                end
            end
            if not close then
                no = no + 1; out[no] = line
            else
                local prefix = line:sub(1, open)  -- includes "{"
                local body = line:sub(open + 1, close - 1)
                local suffix = line:sub(close)    -- starts with "}"
                -- Split body on top-level commas.
                local entries, ne = {}, 0
                local d, s = 0, 1
                for i = 1, #body do
                    local c = body:sub(i, i)
                    if c == "{" or c == "(" or c == "[" then d = d + 1
                    elseif c == "}" or c == ")" or c == "]" then d = d - 1
                    elseif c == "," and d == 0 then
                        ne = ne + 1; entries[ne] = body:sub(s, i - 1):match("^%s*(.-)%s*$")
                        s = i + 1
                    end
                end
                local tail = body:sub(s):match("^%s*(.-)%s*$")
                if tail and tail ~= "" then ne = ne + 1; entries[ne] = tail end
                if ne == 0 then
                    no = no + 1; out[no] = line
                else
                    no = no + 1; out[no] = prefix
                    local inner_indent = indent_match .. opts.indent
                    for i, entry in ipairs(entries) do
                        local sep = (i < ne or opts.trailing_comma) and "," or ""
                        no = no + 1; out[no] = inner_indent .. entry .. sep
                    end
                    no = no + 1; out[no] = indent_match .. suffix
                end
            end
        end
    end
    return out
end

-- ===== Align consecutive assignments ====================================

local function align_assignments(lines)
    local out, no = {}, 0
    local group, gn = {}, 0
    local function flush()
        if gn == 0 then return end
        if gn == 1 then no = no + 1; out[no] = group[1]; group, gn = {}, 0; return end
        -- Find each `=` position; pick max; pad.
        local positions = {}
        local max_eq = 0
        for i = 1, gn do
            -- First standalone `=` not preceded by [=~<>]
            local pos
            local j = 1
            while j <= #group[i] do
                local c = group[i]:sub(j, j)
                if c == "=" then
                    local nxt = group[i]:sub(j + 1, j + 1)
                    local prev = group[i]:sub(j - 1, j - 1)
                    if nxt ~= "=" and prev ~= "=" and prev ~= "~"
                       and prev ~= "<" and prev ~= ">" then
                        pos = j; break
                    end
                end
                j = j + 1
            end
            positions[i] = pos
            if pos and pos > max_eq then max_eq = pos end
        end
        for i = 1, gn do
            local p = positions[i]
            if p and p < max_eq then
                local pad = string.rep(" ", max_eq - p)
                group[i] = group[i]:sub(1, p - 1) .. pad .. group[i]:sub(p)
            end
            no = no + 1; out[no] = group[i]
        end
        group, gn = {}, 0
    end
    for _, line in ipairs(lines) do
        if line:match("^%s*[%w_%.%[%]]+%s*=") and not line:match("^%s*if") and not line:match("^%s*while") then
            gn = gn + 1; group[gn] = line
        else
            flush()
            no = no + 1; out[no] = line
        end
    end
    flush()
    return out
end

-- ===== Top-level entry =================================================

function M.format(src, opts)
    opts = normalize_opts(opts)
    local tokens = tokenize(src)
    local stripped = strip_ws(tokens, opts)
    local lines = render(stripped, opts)
    lines = split_long_tables(lines, opts)
    if opts.align_assignments then lines = align_assignments(lines) end

    -- Strip trailing whitespace per line.
    for i, line in ipairs(lines) do lines[i] = (line:gsub("[ \t]+$", "")) end

    -- Collapse leading/trailing blank lines.
    while lines[1] == "" do table.remove(lines, 1) end
    while lines[#lines] == "" do lines[#lines] = nil end

    local result = table.concat(lines, "\n")
    if #result > 0 then result = result .. "\n" end
    return result
end

function M.format_file(path, opts)
    local f, err = io.open(path, "rb")
    if not f then return false, err end
    local src = f:read("*a"); f:close()
    local out = M.format(src, opts)
    local w, werr = io.open(path, "wb")
    if not w then return false, werr end
    w:write(out); w:close()
    return true
end

-- check(source, opts?) -- true if the source is already in canonical form.
function M.check(src, opts)
    local out = M.format(src, opts)
    return src == out
end

function M.diff(src, opts)
    local out = M.format(src, opts)
    if src == out then return "" end
    -- Minimal unified-style diff (line granularity).
    local a, b = {}, {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do a[#a + 1] = line end
    for line in (out .. "\n"):gmatch("([^\n]*)\n") do b[#b + 1] = line end
    local buf, nb = {}, 0
    nb = nb + 1; buf[nb] = "--- original"
    nb = nb + 1; buf[nb] = "+++ formatted"
    local i, j = 1, 1
    while i <= #a or j <= #b do
        if a[i] == b[j] then
            nb = nb + 1; buf[nb] = " " .. (a[i] or "")
            i = i + 1; j = j + 1
        else
            if a[i] ~= nil then nb = nb + 1; buf[nb] = "-" .. a[i]; i = i + 1 end
            if b[j] ~= nil then nb = nb + 1; buf[nb] = "+" .. b[j]; j = j + 1 end
        end
    end
    return table.concat(buf, "\n")
end

return M
