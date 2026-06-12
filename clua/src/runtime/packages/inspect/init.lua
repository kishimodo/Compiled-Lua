-- inspect -- Pretty-printer for arbitrary Lua values.
--
-- Public surface:
--   inspect(value, opts?)         -> string
--   inspect.value(value, opts?)   -> string         (alias for call form)
--   inspect.diff(a, b, opts?)     -> string         (line-by-line diff of two inspections)
--   inspect.is_marker(s)          -> n | nil        (parses "@N" into N)
--
-- Options:
--   indent              "  "       indentation unit
--   depth               10         max nesting depth before "..."
--   max_string          100        long strings get truncated with "...(N more)"
--   color               false      ANSI color the output
--   sort_keys           true       deterministic key order
--   exclude_metatables  false      skip __metatable display
--   marker_style        "@N"       template for cycle markers; N is replaced with the id
--   inline_threshold    60         tables shorter than this print on one line
--   show_addresses      false      include table/function addresses (non-deterministic)
--   cdata_dump          0          dump first N bytes of cdata pointers/arrays
--
-- The output is intentionally stable across runs (sorted keys, no addresses by
-- default) so it can be used as a snapshot for tests.

local M = {}

local _ANSI = {
    reset    = "\27[0m",
    dim      = "\27[2m",
    str      = "\27[32m",
    num      = "\27[33m",
    bool     = "\27[35m",
    nilv     = "\27[31m",
    key      = "\27[36m",
    typ      = "\27[34m",
    marker   = "\27[95m",
}

local function paint(opts, kind, s)
    if not opts.color then return s end
    local c = _ANSI[kind]
    if not c then return s end
    return c .. s .. _ANSI.reset
end

-- Lua reserved words that cannot be used as bare keys.
local _RESERVED = {
    ["and"]=true,["break"]=true,["do"]=true,["else"]=true,["elseif"]=true,
    ["end"]=true,["false"]=true,["for"]=true,["function"]=true,["goto"]=true,
    ["if"]=true,["in"]=true,["local"]=true,["nil"]=true,["not"]=true,
    ["or"]=true,["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,
    ["until"]=true,["while"]=true,
}

local function is_ident(s)
    if type(s) ~= "string" then return false end
    if _RESERVED[s] then return false end
    return s:match("^[%a_][%w_]*$") ~= nil
end

local _quote_esc = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\0'] = '\\0',
}

local function format_string(s, opts)
    local n = #s
    local trunc = ""
    if n > opts.max_string then
        trunc = string.format("...(%d more)", n - opts.max_string)
        s = s:sub(1, opts.max_string)
    end
    -- Escape control bytes and quote.
    local quoted = s:gsub('[%c"\\]', function(ch)
        local m = _quote_esc[ch]
        if m then return m end
        return string.format("\\x%02x", ch:byte())
    end)
    return paint(opts, "str", '"' .. quoted .. trunc .. '"')
end

local function format_number(n, opts)
    local s
    if math.type and math.type(n) == "integer" then
        s = tostring(n)
    elseif n ~= n then
        s = "nan"
    elseif n == math.huge then
        s = "inf"
    elseif n == -math.huge then
        s = "-inf"
    else
        s = tostring(n)
    end
    return paint(opts, "num", s)
end

local function format_key(k, opts)
    if is_ident(k) then
        return paint(opts, "key", k)
    elseif type(k) == "string" then
        return "[" .. format_string(k, opts) .. "]"
    elseif type(k) == "number" then
        return "[" .. format_number(k, opts) .. "]"
    elseif type(k) == "boolean" then
        return "[" .. paint(opts, "bool", tostring(k)) .. "]"
    else
        return "[" .. tostring(k) .. "]"
    end
end

-- Render a cdata value when ffi is available; otherwise tostring it.
local function format_cdata(v, opts)
    local has_ffi, ffi = pcall(require, "ffi")
    if not has_ffi or not ffi then
        return paint(opts, "typ", tostring(v))
    end
    local ok, ctype = pcall(ffi.typeof, v)
    local tname = ok and tostring(ctype) or "cdata"
    -- Scalar number-like cdata: print the value.
    local ok2, asnum = pcall(tonumber, v)
    if ok2 and asnum ~= nil and type(asnum) == "number" then
        return paint(opts, "typ", tname) .. "(" .. paint(opts, "num", tostring(asnum)) .. ")"
    end
    -- Pointer / array / struct: print address + optional byte dump.
    local addr
    local ok3, ptrval = pcall(function() return tonumber(ffi.cast("uintptr_t", v)) end)
    if ok3 and ptrval then addr = string.format("0x%x", ptrval) end
    local out = paint(opts, "typ", tname) .. (addr and ("@" .. addr) or "")
    if opts.cdata_dump and opts.cdata_dump > 0 and addr then
        local n = opts.cdata_dump
        local ok4, bytes = pcall(function()
            local p = ffi.cast("uint8_t*", v)
            local parts = {}
            for i = 0, n - 1 do parts[i + 1] = string.format("%02x", p[i]) end
            return table.concat(parts, " ")
        end)
        if ok4 then out = out .. " <" .. bytes .. ">" end
    end
    return out
end

-- Render a function: use debug.getinfo for source/line if available.
local function format_function(v, opts)
    if not opts.show_function_info then
        return paint(opts, "typ", "function")
    end
    local info = debug and debug.getinfo and debug.getinfo(v, "Su")
    if info and info.source then
        local src = info.source
        if src:sub(1, 1) == "@" then src = src:sub(2) end
        local line = info.linedefined and info.linedefined > 0 and (":" .. info.linedefined) or ""
        local upn = info.nups and info.nups > 0 and (" ups=" .. info.nups) or ""
        return paint(opts, "typ", "function") .. "<" .. src .. line .. upn .. ">"
    end
    return paint(opts, "typ", "function") .. "<?>"
end

-- Build a stable sort: numbers first by value, then strings by string, then
-- other types by type-then-tostring.
local function key_sort(a, b)
    local ta, tb = type(a), type(b)
    if ta == tb then
        if ta == "number" or ta == "string" then return a < b end
        return tostring(a) < tostring(b)
    end
    -- Type priority: number < string < boolean < other
    local order = { number = 1, string = 2, boolean = 3 }
    return (order[ta] or 99) < (order[tb] or 99)
end

-- Estimate inline length of a rendered fragment (strip ANSI for accuracy).
local function visible_len(s)
    return #(s:gsub("\27%[[%d;]*m", ""))
end

local _render
_render = function(v, opts, depth, seen, marker_count)
    -- Optional user processor: lets callers redact / replace any value.
    if opts.process then
        local replaced = opts.process(v, depth)
        if replaced ~= v then v = replaced end
    end
    local t = type(v)
    if t == "nil" then
        return paint(opts, "nilv", "nil")
    elseif t == "boolean" then
        return paint(opts, "bool", tostring(v))
    elseif t == "number" then
        return format_number(v, opts)
    elseif t == "string" then
        return format_string(v, opts)
    elseif t == "function" then
        return format_function(v, opts)
    elseif t == "thread" then
        local addr = tostring(v):match(":%s*(.+)$") or "?"
        return paint(opts, "typ", "thread") .. "<" .. addr .. ">"
    elseif t == "userdata" then
        return paint(opts, "typ", "userdata") .. "<" .. tostring(v) .. ">"
    elseif t == "cdata" then
        return format_cdata(v, opts)
    elseif t ~= "table" then
        return tostring(v)
    end

    -- Cycle: this table is already on the path being rendered.
    if seen[v] then
        local marker = opts.marker_style:gsub("N", tostring(seen[v]))
        return paint(opts, "marker", marker)
    end
    if depth >= opts.depth then
        return "{ ... }"
    end

    -- Assign a marker id once we descend, so cycles can refer back.
    marker_count[1] = marker_count[1] + 1
    local my_id = marker_count[1]
    seen[v] = my_id

    -- Collect keys, separating sequence part from hash part.
    local n_seq = #v
    local hash_keys, nh = {}, 0
    for k in pairs(v) do
        local is_seq = (type(k) == "number" and k >= 1 and k <= n_seq and k == math.floor(k))
        if not is_seq then nh = nh + 1; hash_keys[nh] = k end
    end
    if opts.sort_keys then table.sort(hash_keys, key_sort) end

    -- Empty table.
    if n_seq == 0 and nh == 0 then
        seen[v] = nil
        return "{}"
    end

    -- Render every entry first; we may collapse to one line afterwards.
    local entries, ne = {}, 0
    local seq_limit = (opts.max_array and opts.max_array > 0) and opts.max_array or n_seq
    local seq_show = math.min(n_seq, seq_limit)
    for i = 1, seq_show do
        ne = ne + 1
        entries[ne] = _render(v[i], opts, depth + 1, seen, marker_count)
    end
    if seq_show < n_seq then
        ne = ne + 1
        entries[ne] = paint(opts, "dim", string.format("...(%d more)", n_seq - seq_show))
    end
    for i = 1, nh do
        local k = hash_keys[i]
        local kstr = format_key(k, opts)
        local vstr = _render(v[k], opts, depth + 1, seen, marker_count)
        ne = ne + 1
        entries[ne] = kstr .. " = " .. vstr
    end

    -- Metatable display.
    local mt_str
    if not opts.exclude_metatables then
        local mt = getmetatable(v)
        if mt ~= nil then
            mt_str = paint(opts, "dim", "<metatable>") .. " = " .. _render(mt, opts, depth + 1, seen, marker_count)
        end
    end

    seen[v] = nil  -- pop from path: siblings can re-render this table fresh

    -- Try inline (single-line) rendering first.
    local inline = "{ " .. table.concat(entries, ", ") .. (mt_str and (", " .. mt_str) or "") .. " }"
    if visible_len(inline) <= opts.inline_threshold and not inline:find("\n", 1, true) then
        return inline
    end

    -- Multi-line.
    local nl = opts.newline or "\n"
    local pad = opts.indent:rep(depth + 1)
    local close_pad = opts.indent:rep(depth)
    local body = {}
    for i, e in ipairs(entries) do body[i] = pad .. e end
    if mt_str then body[#body + 1] = pad .. mt_str end
    return "{" .. nl .. table.concat(body, "," .. nl) .. nl .. close_pad .. "}"
end

local function normalize_opts(opts)
    opts = opts or {}
    -- Translate spec-style option aliases (show_metatables, max_array, newline,
    -- show_function_info, process) into internal canonical fields.
    local exclude_mt
    if opts.exclude_metatables ~= nil then
        exclude_mt = opts.exclude_metatables
    elseif opts.show_metatables ~= nil then
        exclude_mt = not opts.show_metatables
    else
        exclude_mt = true  -- default: omit metatables (closer to common pretty-printers)
    end
    return {
        indent             = opts.indent             or "  ",
        newline            = opts.newline            or "\n",
        depth              = opts.depth              or 10,
        max_string         = opts.max_string         or opts.max_string or 100,
        max_array          = opts.max_array          or 0,         -- 0 = unlimited
        color              = opts.color              or false,
        sort_keys          = opts.sort_keys ~= false,
        exclude_metatables = exclude_mt,
        show_function_info = opts.show_function_info ~= false,
        marker_style       = opts.marker_style       or "@N",
        inline_threshold   = opts.inline_threshold   or 60,
        show_addresses     = opts.show_addresses     or false,
        cdata_dump         = opts.cdata_dump         or 0,
        process            = opts.process            or nil,
    }
end

function M.value(v, opts)
    opts = normalize_opts(opts)
    return _render(v, opts, 0, {}, { 0 })
end

-- Spec alias: inspect.inspect(value, opts?).
M.inspect = M.value

-- pp(value, opts?) -- print + return, useful at the REPL.
function M.pp(v, opts)
    local s = M.value(v, opts)
    print(s)
    return v
end

-- compact(v) -- one-line rendering (no embedded newlines).
function M.compact(v, opts)
    opts = opts or {}
    local clone = {}
    for k, val in pairs(opts) do clone[k] = val end
    clone.newline = ""
    clone.indent  = ""
    clone.inline_threshold = math.huge
    return M.value(v, clone)
end

-- to_lua(value) -- emit a Lua expression that round-trips with load().
-- Strings get %q, numbers and booleans use tostring, tables get recursive emit.
-- Functions / userdata / threads / cdata aren't representable; they become
-- a stringified placeholder so the value is at least visible.
local function _to_lua(v, seen, depth)
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v then return "0/0" end
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        if math.type and math.type(v) == "integer" then return tostring(v) end
        return string.format("%.17g", v)
    end
    if t == "string" then return string.format("%q", v) end
    if t == "table" then
        if seen[v] then return "{--[[cycle]]}" end
        seen[v] = true
        local parts, np = {}, 0
        local n = #v
        for i = 1, n do
            np = np + 1
            parts[np] = _to_lua(v[i], seen, depth + 1)
        end
        local hash_keys, nh = {}, 0
        for k in pairs(v) do
            local is_seq = (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k))
            if not is_seq then nh = nh + 1; hash_keys[nh] = k end
        end
        table.sort(hash_keys, function(a, b)
            if type(a) == type(b) then return tostring(a) < tostring(b) end
            return type(a) < type(b)
        end)
        for _, k in ipairs(hash_keys) do
            local key_lit
            if type(k) == "string" and k:match("^[%a_][%w_]*$") and not ({
                ["and"]=1,["or"]=1,["not"]=1,["nil"]=1,["true"]=1,["false"]=1,
                ["if"]=1,["then"]=1,["else"]=1,["elseif"]=1,["end"]=1,
                ["for"]=1,["in"]=1,["do"]=1,["while"]=1,["repeat"]=1,["until"]=1,
                ["function"]=1,["return"]=1,["local"]=1,["break"]=1,["goto"]=1,
            })[k] then
                key_lit = k
            else
                key_lit = "[" .. _to_lua(k, seen, depth + 1) .. "]"
            end
            np = np + 1
            parts[np] = key_lit .. " = " .. _to_lua(v[k], seen, depth + 1)
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    -- Non-representable: emit a comment-tagged string placeholder.
    return string.format("%q --[[%s]]", tostring(v), t)
end

function M.to_lua(v)
    return _to_lua(v, {}, 0)
end

-- Allow `inspect(v, opts)` as well as `inspect.value(v, opts)`.
setmetatable(M, { __call = function(_, v, opts) return M.value(v, opts) end })

function M.is_marker(s)
    if type(s) ~= "string" then return nil end
    local n = s:match("^@(%d+)$")
    return n and tonumber(n) or nil
end

-- Line-by-line diff of two inspections. Useful for snapshot test failures.
function M.diff(a, b, opts)
    local sa = M.value(a, opts)
    local sb = M.value(b, opts)
    if sa == sb then return "" end
    local la, lb = {}, {}
    for line in (sa .. "\n"):gmatch("([^\n]*)\n") do la[#la + 1] = line end
    for line in (sb .. "\n"):gmatch("([^\n]*)\n") do lb[#lb + 1] = line end
    local out, no = {}, 0
    local i, j = 1, 1
    while i <= #la or j <= #lb do
        local av = la[i]
        local bv = lb[j]
        if av == bv then
            no = no + 1; out[no] = "  " .. (av or "")
            i = i + 1; j = j + 1
        else
            if av ~= nil then no = no + 1; out[no] = "- " .. av; i = i + 1 end
            if bv ~= nil then no = no + 1; out[no] = "+ " .. bv; j = j + 1 end
        end
    end
    return table.concat(out, "\n")
end

return M
