-- cli -- Argparse-style command-line parser with subcommands and completion.
--
-- Public surface:
--   cli.new({name, description, version})  -> parser
--   parser:argument(name, opts?)            -- positional
--   parser:option(name, opts?)              -- --long / -short
--   parser:flag(name, opts?)                -- boolean
--   parser:subcommand(name, opts?)          -> sub-parser
--   parser:parse(argv?)                     -> args table
--   parser:help()                           -> string
--   parser:gen_completion("bash"|"pwsh")    -> string
--
-- opts shape:
--   default     -- value used when arg is absent
--   required    -- bool
--   type        -- "string"|"int"|"float"|"bool" (default "string")
--   choices     -- array of permitted string values
--   multi       -- bool; option may be repeated, value becomes a table
--   help        -- description shown in --help
--   short       -- one-letter alias (e.g. "v" for --verbose)
--   action      -- fn(args, value) called when matched; bypasses storage
--   metavar     -- placeholder name in help text (e.g. "FILE")
--
-- parse() returns a flat table where positionals and options share the
-- namespace. Subcommands appear as args.subcommand = "name" and
-- args[name] = { ...sub-args... }.

local M = {}

local Parser = {}
Parser.__index = Parser

local function lazy_color()
    local ok, c = pcall(require, "color")
    if ok then return c end
    -- Minimal stub when color isn't available so help still renders.
    return {
        bold = function(s) return s end, dim = function(s) return s end,
        cyan = function(s) return s end, yellow = function(s) return s end,
        red  = function(s) return s end, green = function(s) return s end,
    }
end

-- ===== Construction =================================================

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        name        = opts.name        or "program",
        description = opts.description or "",
        version     = opts.version     or nil,
        epilog      = opts.epilog      or nil,
        _positionals = {},
        _options     = {},
        _flags       = {},
        _by_long     = {},       -- "--foo" -> entry
        _by_short    = {},       -- "-f"    -> entry
        _subcommands = {},
        _sub_order   = {},
        _parent      = nil,
    }, Parser)
end

-- ===== Schema helpers ===============================================

local function normalize_option_opts(opts)
    opts = opts or {}
    opts.type = opts.type or "string"
    return opts
end

function Parser:argument(name, opts)
    opts = normalize_option_opts(opts)
    opts.name = name
    self._positionals[#self._positionals+1] = opts
    return self
end

function Parser:option(name, opts)
    opts = normalize_option_opts(opts)
    opts.name = name
    opts.long = "--" .. name
    self._options[#self._options+1] = opts
    self._by_long[opts.long] = opts
    if opts.short then
        self._by_short["-" .. opts.short] = opts
    end
    return self
end

function Parser:flag(name, opts)
    opts = normalize_option_opts(opts)
    opts.name = name
    opts.type = "bool"
    opts.long = "--" .. name
    -- Also accept --no-name to explicitly clear the flag (handy for env-derived
    -- defaults that the user wants to override on a one-off invocation).
    self._flags[#self._flags+1] = opts
    self._by_long[opts.long] = opts
    self._by_long["--no-" .. name] = setmetatable({ _negate = true }, { __index = opts })
    if opts.short then
        self._by_short["-" .. opts.short] = opts
    end
    return self
end

function Parser:subcommand(name, opts)
    opts = opts or {}
    local sub = M.new({
        name        = self.name .. " " .. name,
        description = opts.description or "",
        version     = self.version,
    })
    sub._parent = self
    self._subcommands[name] = sub
    self._sub_order[#self._sub_order+1] = name
    return sub
end

-- ===== Value coercion ==============================================

local function coerce(value, opts, context)
    if opts.type == "int" then
        local n = tonumber(value, 10)
        if not n or n ~= math.floor(n) then
            error(context .. ": expected integer, got '" .. value .. "'", 0)
        end
        return math.floor(n)
    elseif opts.type == "float" then
        local n = tonumber(value)
        if not n then error(context .. ": expected number, got '" .. value .. "'", 0) end
        return n
    elseif opts.type == "bool" then
        if value == "true" or value == "yes" or value == "1" then return true end
        if value == "false" or value == "no" or value == "0" then return false end
        error(context .. ": expected bool, got '" .. value .. "'", 0)
    else
        if opts.choices then
            local found = false
            for _, c in ipairs(opts.choices) do
                if c == value then found = true; break end
            end
            if not found then
                error(context .. ": '" .. value .. "' not in {" .. table.concat(opts.choices, ", ") .. "}", 0)
            end
        end
        return value
    end
end

-- ===== Parse ========================================================

local function default_argv()
    -- LuaVM passes argv through the global `arg` table just like stock Lua.
    if arg then
        local out = {}
        for i = 1, #arg do out[i] = arg[i] end
        return out
    end
    return {}
end

local function store(args, opts, value)
    if opts.action then
        opts.action(args, value)
        return
    end
    if opts.multi then
        args[opts.name] = args[opts.name] or {}
        table.insert(args[opts.name], value)
    else
        args[opts.name] = value
    end
end

function Parser:parse(argv)
    argv = argv or default_argv()
    local args = {}
    local positional_idx = 1
    local i = 1

    -- Apply defaults first.
    for _, p in ipairs(self._positionals) do
        if p.default ~= nil then args[p.name] = p.default end
    end
    for _, o in ipairs(self._options) do
        if o.default ~= nil then args[o.name] = o.default end
    end
    for _, f in ipairs(self._flags) do
        if f.default ~= nil then args[f.name] = f.default
        else args[f.name] = false end
    end

    while i <= #argv do
        local token = argv[i]
        if token == "--" then
            -- Everything after is positional.
            for j = i + 1, #argv do
                local p = self._positionals[positional_idx]
                if not p then error("unexpected positional: " .. argv[j], 0) end
                store(args, p, coerce(argv[j], p, p.name))
                positional_idx = positional_idx + 1
            end
            break
        elseif token == "-h" or token == "--help" then
            io.write(self:help())
            os.exit(0)
        elseif token == "--version" and self.version then
            io.write(self.name .. " " .. self.version .. "\n")
            os.exit(0)
        elseif token:sub(1, 2) == "--" then
            local eq = token:find("=", 1, true)
            local key, inline_val
            if eq then
                key = token:sub(1, eq - 1)
                inline_val = token:sub(eq + 1)
            else
                key = token
            end
            local opt = self._by_long[key]
            if not opt then error("unknown option: " .. key, 0) end
            if opt.type == "bool" then
                if opt._negate then
                    store(args, opt, false)
                else
                    store(args, opt, inline_val == nil and true or (inline_val == "true" or inline_val == "1"))
                end
            else
                local v = inline_val
                if v == nil then
                    i = i + 1
                    v = argv[i]
                    if v == nil then error("option " .. key .. " requires a value", 0) end
                end
                store(args, opt, coerce(v, opt, key))
            end
        elseif token:sub(1, 1) == "-" and #token > 1 then
            -- -x or -xvalue or bundled flags -abc
            -- We try short-name lookup, treating the remainder as inline value
            -- if the entry isn't a bool. Bundled flags work only for bool opts.
            local s = "-" .. token:sub(2, 2)
            local opt = self._by_short[s]
            if not opt then error("unknown option: " .. s, 0) end
            if opt.type == "bool" then
                store(args, opt, true)
                -- handle bundle -abc: try each remaining char as a short flag
                for k = 3, #token do
                    local s2 = "-" .. token:sub(k, k)
                    local opt2 = self._by_short[s2]
                    if not opt2 then error("unknown option in bundle: " .. s2, 0) end
                    if opt2.type ~= "bool" then
                        error("non-bool option " .. s2 .. " cannot be bundled", 0)
                    end
                    store(args, opt2, true)
                end
            else
                local v = token:sub(3)
                if v == "" then
                    i = i + 1
                    v = argv[i]
                    if v == nil then error("option " .. s .. " requires a value", 0) end
                end
                store(args, opt, coerce(v, opt, s))
            end
        elseif next(self._subcommands) and positional_idx > #self._positionals then
            local sub = self._subcommands[token]
            if not sub then
                error("unknown subcommand: " .. token, 0)
            end
            args.subcommand = token
            -- Slice the rest for the sub-parser.
            local rest = {}
            for j = i + 1, #argv do rest[#rest+1] = argv[j] end
            args[token] = sub:parse(rest)
            return args
        else
            local p = self._positionals[positional_idx]
            if not p then error("unexpected positional: " .. token, 0) end
            store(args, p, coerce(token, p, p.name))
            positional_idx = positional_idx + 1
        end
        i = i + 1
    end

    -- Required-arg checks.
    for _, p in ipairs(self._positionals) do
        if p.required and args[p.name] == nil then
            error("missing required argument: " .. p.name, 0)
        end
    end
    for _, o in ipairs(self._options) do
        if o.required and args[o.name] == nil then
            error("missing required option: --" .. o.name, 0)
        end
    end

    -- If we have subcommands and none was provided, that's not necessarily an
    -- error unless the parser was configured with required_subcommand. We
    -- leave the check to the caller.
    return args
end

-- ===== Help generation =============================================

local function fmt_option_signature(opt)
    local sig
    if opt.short then sig = "-" .. opt.short .. ", " .. opt.long
    else sig = "    " .. opt.long end
    if opt.type ~= "bool" then
        sig = sig .. " <" .. (opt.metavar or opt.type) .. ">"
    end
    return sig
end

function Parser:help()
    local c = lazy_color()
    local out = {}
    out[#out+1] = c.bold(self.name)
    if self.version then out[#out+1] = "  version " .. self.version end
    if self.description and self.description ~= "" then
        out[#out+1] = ""
        out[#out+1] = self.description
    end
    out[#out+1] = ""

    -- Usage line.
    local usage = { "usage:", self.name }
    if next(self._options) or next(self._flags) then usage[#usage+1] = "[options]" end
    for _, p in ipairs(self._positionals) do
        local label = p.metavar or ("<" .. p.name .. ">")
        usage[#usage+1] = p.required and label or "[" .. label .. "]"
    end
    if next(self._subcommands) then
        usage[#usage+1] = "<command> [<args>]"
    end
    out[#out+1] = table.concat(usage, " ")

    if #self._positionals > 0 then
        out[#out+1] = ""
        out[#out+1] = c.bold("arguments:")
        for _, p in ipairs(self._positionals) do
            local label = string.format("  %-22s", p.name)
            out[#out+1] = label .. (p.help or "")
        end
    end

    local opts_and_flags = {}
    for _, o in ipairs(self._options) do opts_and_flags[#opts_and_flags+1] = o end
    for _, f in ipairs(self._flags) do opts_and_flags[#opts_and_flags+1] = f end
    if #opts_and_flags > 0 then
        out[#out+1] = ""
        out[#out+1] = c.bold("options:")
        for _, o in ipairs(opts_and_flags) do
            local sig = fmt_option_signature(o)
            local help = o.help or ""
            if o.default ~= nil and o.type ~= "bool" then
                help = help .. c.dim(" (default: " .. tostring(o.default) .. ")")
            end
            if o.choices then
                help = help .. c.dim(" {" .. table.concat(o.choices, "|") .. "}")
            end
            out[#out+1] = string.format("  %-32s %s", sig, help)
        end
        out[#out+1] = string.format("  %-32s %s", "-h, --help", "show this help and exit")
        if self.version then
            out[#out+1] = string.format("  %-32s %s", "--version", "print version and exit")
        end
    end

    if next(self._subcommands) then
        out[#out+1] = ""
        out[#out+1] = c.bold("commands:")
        for _, name in ipairs(self._sub_order) do
            local sub = self._subcommands[name]
            out[#out+1] = string.format("  %-22s %s", name, sub.description or "")
        end
    end

    if self.epilog then
        out[#out+1] = ""
        out[#out+1] = self.epilog
    end

    return table.concat(out, "\n") .. "\n"
end

-- ===== Completion ==================================================

local function collect_long_options(parser)
    local out = {}
    for _, o in ipairs(parser._options) do out[#out+1] = o.long end
    for _, f in ipairs(parser._flags) do
        out[#out+1] = f.long
        out[#out+1] = "--no-" .. f.name
    end
    out[#out+1] = "--help"
    if parser.version then out[#out+1] = "--version" end
    return out
end

local function gen_bash(parser)
    -- Single _<name>_complete function that walks the command line and dispatches
    -- to subcommand suggestion lists.
    local fn_name = "_" .. parser.name:gsub("%W", "_") .. "_complete"
    local longs = collect_long_options(parser)
    local subs = {}
    for _, n in ipairs(parser._sub_order) do subs[#subs+1] = n end
    -- Per-sub option lists.
    local sub_dispatch = {}
    for _, name in ipairs(parser._sub_order) do
        local sub = parser._subcommands[name]
        local sub_opts = collect_long_options(sub)
        sub_dispatch[#sub_dispatch+1] = string.format(
            "    %s)\n      COMPREPLY=( $(compgen -W %q -- \"$cur\") )\n      return 0\n      ;;",
            name, table.concat(sub_opts, " "))
    end
    return string.format([[
%s() {
  local cur prev words cword
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  if [ $COMP_CWORD -ge 2 ]; then
    case "${COMP_WORDS[1]}" in
%s
    esac
  fi
  COMPREPLY=( $(compgen -W %q -- "$cur") )
}
complete -F %s %s
]], fn_name, table.concat(sub_dispatch, "\n"),
    table.concat(longs, " ") .. " " .. table.concat(subs, " "),
    fn_name, parser.name)
end

local function gen_pwsh(parser)
    -- PowerShell ArgumentCompleter that returns a flat candidate list.
    local longs = collect_long_options(parser)
    local subs = {}
    for _, n in ipairs(parser._sub_order) do subs[#subs+1] = n end

    local sub_cases = {}
    for _, name in ipairs(parser._sub_order) do
        local sub = parser._subcommands[name]
        local sub_opts = collect_long_options(sub)
        local quoted = {}
        for _, o in ipairs(sub_opts) do quoted[#quoted+1] = "'" .. o .. "'" end
        sub_cases[#sub_cases+1] = string.format("    '%s' { @(%s) }", name, table.concat(quoted, ","))
    end

    local longs_q = {}
    for _, o in ipairs(longs) do longs_q[#longs_q+1] = "'" .. o .. "'" end
    for _, s in ipairs(subs) do longs_q[#longs_q+1] = "'" .. s .. "'" end

    return string.format([[
Register-ArgumentCompleter -Native -CommandName '%s' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $tokens = $commandAst.CommandElements
    $subCmd = if ($tokens.Count -ge 2) { $tokens[1].Value } else { $null }
    $candidates = switch ($subCmd) {
%s
        default { @(%s) }
    }
    $candidates | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_)
    }
}
]], parser.name, table.concat(sub_cases, "\n"), table.concat(longs_q, ","))
end

function Parser:gen_completion(shell)
    if shell == "bash" then return gen_bash(self) end
    if shell == "pwsh" or shell == "powershell" then return gen_pwsh(self) end
    error("cli: unknown shell '" .. tostring(shell) .. "' (want 'bash' or 'pwsh')", 0)
end

return M
