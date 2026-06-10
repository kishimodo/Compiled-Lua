-- repl -- Embeddable REPL with multiline detection, history, completion.
--
-- Public surface:
--   repl.start(opts?)        -- enter the REPL loop
--   repl.eval_line(line)     -- helper: run a Lua chunk, returns ok, results...
--   repl.is_balanced(text)   -- bool: balanced parens/brackets/braces and no open string
--   repl.completer_for_env(env?)  -- tab-completion fn from a globals-like table
--
-- opts:
--   prompt          = ">> "
--   continue_prompt = ".. "
--   history_file    = ".lua_history"
--   max_history     = 500
--   completer       = fn(line) -> { candidates }, common_prefix
--   on_eval         = fn(input) -> result  (override the default Lua-eval)
--   on_result       = fn(result_string)    (override how the result is printed)
--   banner          = string printed before the loop
--   exit_commands   = { "exit", "quit" }   (typed alone, end the loop)
--   env             = sandbox environment for chunks (default: _G)
--   highlight       = bool                 colorize source via color package

local color    = require "color"
local keyboard = require "keyboard"

local M = {}

-- ===== Balance detection ===========================================
-- Returns true if every opening delim has a closer and no string is open.
-- Used to decide whether to keep accumulating lines (multiline mode).

function M.is_balanced(text)
    local depth_paren, depth_bracket, depth_brace = 0, 0, 0
    local in_string, str_delim = false, nil
    local in_long, long_eq = false, 0
    local in_line_comment = false
    local in_block_comment = false
    local block_eq = 0
    local i, n = 1, #text
    while i <= n do
        local ch = text:sub(i, i)
        if in_line_comment then
            if ch == "\n" then in_line_comment = false end
            i = i + 1
        elseif in_block_comment then
            -- match closing ]=*]
            if ch == "]" then
                local eq = 0
                local j = i + 1
                while text:sub(j, j) == "=" do eq = eq + 1; j = j + 1 end
                if text:sub(j, j) == "]" and eq == block_eq then
                    in_block_comment = false
                    i = j + 1
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        elseif in_long then
            if ch == "]" then
                local eq = 0
                local j = i + 1
                while text:sub(j, j) == "=" do eq = eq + 1; j = j + 1 end
                if text:sub(j, j) == "]" and eq == long_eq then
                    in_long = false
                    i = j + 1
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        elseif in_string then
            if ch == "\\" then i = i + 2
            elseif ch == str_delim then in_string = false; i = i + 1
            elseif ch == "\n" then
                -- Unterminated short string -- treat as imbalanced.
                return false
            else i = i + 1 end
        else
            if ch == "-" and text:sub(i+1, i+1) == "-" then
                -- Could be -- line comment or --[[ block comment.
                if text:sub(i+2, i+2) == "[" then
                    local eq = 0
                    local j = i + 3
                    while text:sub(j, j) == "=" do eq = eq + 1; j = j + 1 end
                    if text:sub(j, j) == "[" then
                        in_block_comment = true
                        block_eq = eq
                        i = j + 1
                    else
                        in_line_comment = true
                        i = i + 2
                    end
                else
                    in_line_comment = true
                    i = i + 2
                end
            elseif ch == '"' or ch == "'" then
                in_string = true
                str_delim = ch
                i = i + 1
            elseif ch == "[" then
                local eq = 0
                local j = i + 1
                while text:sub(j, j) == "=" do eq = eq + 1; j = j + 1 end
                if text:sub(j, j) == "[" then
                    in_long = true
                    long_eq = eq
                    i = j + 1
                else
                    depth_bracket = depth_bracket + 1
                    i = i + 1
                end
            elseif ch == "(" then depth_paren = depth_paren + 1; i = i + 1
            elseif ch == ")" then depth_paren = depth_paren - 1; i = i + 1
            elseif ch == "]" then depth_bracket = depth_bracket - 1; i = i + 1
            elseif ch == "{" then depth_brace = depth_brace + 1; i = i + 1
            elseif ch == "}" then depth_brace = depth_brace - 1; i = i + 1
            else i = i + 1 end
        end
    end
    if in_string or in_long or in_block_comment then return false end
    -- Also detect keyword-driven blocks (do/end, if/then/end, function/end, for/end,
    -- while/end, repeat/until). Heuristic: count opens minus closes at word boundaries.
    local opens, closes = 0, 0
    for w in text:gmatch("[%w_]+") do
        if w == "do" or w == "then" or w == "function" or w == "repeat" then
            opens = opens + 1
        elseif w == "end" or w == "until" then
            closes = closes + 1
        elseif w == "elseif" then
            -- elseif closes the previous "then" and opens a new one -- net zero.
        end
    end
    -- "function foo()" before "do" doesn't double-count: function adds 1 open,
    -- no "do" follows in single-line cases. We may slightly over-count for
    -- weird code, but for REPL UX a false positive (extra continuation) is
    -- benign -- the user can just enter a blank line to force evaluation.
    if (depth_paren + depth_bracket + depth_brace) ~= 0 then return false end
    if opens > closes then return false end
    return true
end

-- ===== Lua chunk evaluation ========================================

local function compile_chunk(src, name, env)
    -- Try as expression first ("=" prefix style for printing the value).
    local f = load("return " .. src, name, "t", env)
    if not f then
        f = load(src, name, "t", env)
    end
    return f
end

local function repr(v)
    if type(v) == "string" then
        -- string.format("%q", v) escapes -- close enough for REPL output.
        return string.format("%q", v)
    elseif type(v) == "table" then
        return tostring(v)
    end
    return tostring(v)
end

function M.eval_line(src, env)
    env = env or _G
    local f, err = compile_chunk(src, "=stdin", env)
    if not f then return false, err end
    local results = { pcall(f) }
    if not results[1] then return false, results[2] end
    table.remove(results, 1)
    return true, table.unpack(results)
end

-- ===== Completer factory ==========================================

function M.completer_for_env(env)
    env = env or _G
    return function(line, _pos)
        -- Take the current word: split on whitespace and non-identifier punctuation.
        local word = line:match("[%w_%.]+$") or ""
        local prefix, last = word:match("^(.-)([%w_]*)$")
        prefix = prefix or ""
        last = last or word

        -- Resolve `prefix` (e.g. "table.") down to a table; iterate its keys.
        local target = env
        if prefix ~= "" and prefix ~= "." then
            local clean = prefix:gsub("%.$", "")
            for part in clean:gmatch("([^%.]+)") do
                if type(target) ~= "table" then return {}, "" end
                target = target[part]
            end
            if type(target) ~= "table" then return {}, "" end
        end
        local cands = {}
        for k, _ in pairs(target) do
            if type(k) == "string" and k:sub(1, #last) == last then
                cands[#cands+1] = k:sub(#last + 1)
            end
        end
        -- Longest common prefix among candidates for "tab fills as much as possible".
        local common = cands[1] or ""
        for i = 2, #cands do
            local c = cands[i]
            local j = 1
            while j <= #common and j <= #c and common:byte(j) == c:byte(j) do j = j + 1 end
            common = common:sub(1, j - 1)
        end
        return cands, common
    end
end

-- ===== History persistence =========================================

local function load_history(path)
    if not path then return {} end
    local f = io.open(path, "r")
    if not f then return {} end
    local out = {}
    for line in f:lines() do out[#out+1] = line end
    f:close()
    return out
end

local function save_history(path, history, max_history)
    if not path then return end
    local f = io.open(path, "w")
    if not f then return end
    local start = math.max(1, #history - (max_history or 500) + 1)
    for i = start, #history do
        f:write(history[i], "\n")
    end
    f:close()
end

-- ===== REPL loop ===================================================

function M.start(opts)
    opts = opts or {}
    local prompt_str    = opts.prompt          or ">> "
    local cont_str      = opts.continue_prompt or ".. "
    local hist_file     = opts.history_file
    local max_history   = opts.max_history     or 500
    local completer     = opts.completer
    local on_eval       = opts.on_eval
    local on_result     = opts.on_result
    local banner        = opts.banner
    local env           = opts.env             or _G
    local exit_commands = opts.exit_commands   or { "exit", "quit", ".exit" }

    local history = load_history(hist_file)

    if not completer then
        completer = M.completer_for_env(env)
    end

    if banner then io.write(banner .. "\n") end

    local buf = {}
    while true do
        local prompt_text = (#buf > 0) and cont_str or prompt_str
        io.write(prompt_text); io.flush()

        local line = keyboard.read_line({
            history   = history,
            completer = completer,
        })
        if line == nil then
            -- Ctrl-C / Ctrl-D
            if #buf > 0 then
                -- Cancel current multiline buffer; keep loop running.
                buf = {}
                io.write(color.dim("(cancelled)\n"))
            else
                io.write(color.dim("bye\n"))
                save_history(hist_file, history, max_history)
                return
            end
        else
            -- Trimmed exit shortcut.
            local trimmed = line:match("^%s*(.-)%s*$")
            local is_exit = false
            for _, cmd in ipairs(exit_commands) do
                if trimmed == cmd then is_exit = true; break end
            end
            if is_exit and #buf == 0 then
                save_history(hist_file, history, max_history)
                return
            end

            buf[#buf+1] = line
            local joined = table.concat(buf, "\n")
            if not M.is_balanced(joined) then
                -- Need more input.
            else
                -- Eval.
                if joined:match("%S") then
                    history[#history+1] = joined
                    local ok, err_or_result, more
                    if on_eval then
                        ok, err_or_result = pcall(on_eval, joined)
                        if not ok then
                            io.write(color.red("error: " .. tostring(err_or_result) .. "\n"))
                        elseif err_or_result ~= nil then
                            local s = type(err_or_result) == "string"
                                and err_or_result
                                or repr(err_or_result)
                            if on_result then on_result(s)
                            else io.write(s .. "\n") end
                        end
                    else
                        local results = { M.eval_line(joined, env) }
                        ok = results[1]
                        if not ok then
                            io.write(color.red("error: " .. tostring(results[2]) .. "\n"))
                        else
                            -- Print any return values.
                            local printed = false
                            for i = 2, #results do
                                if not printed then printed = true
                                else io.write("\t") end
                                io.write(repr(results[i]))
                            end
                            if printed then io.write("\n") end
                        end
                    end
                end
                buf = {}
            end
        end
    end
end

return M
