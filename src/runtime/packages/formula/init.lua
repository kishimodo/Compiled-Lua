-- formula -- spreadsheet-style formula parser + evaluator.
--
-- SECURITY NOTE:
--   This module never calls `load` / `loadstring` on user input. Formulas are
--   parsed into an AST and walked by the manual interpreter below, so the
--   only code paths reachable from a formula are the FUNCS table entries
--   defined in this file. Cell resolution goes through the caller-supplied
--   ctx:get and cannot access anything ctx does not expose. Treat this as a
--   pure data-driven evaluator, not a script host.
--
-- Public surface:
--   formula.parse(text)        -> ast, err
--   formula.eval(text, ctx)    -> value
--   formula.errors             -> { REF="#REF!", VALUE="#VALUE!", ... }
--   formula.is_error(v)        -> bool
--   formula.col_to_index(letters) -> integer  (A=1, Z=26, AA=27, ...)
--   formula.index_to_col(n)       -> letters
--
-- Context (`ctx`):
--   ctx:get(ref) -> value
--     ref is one of:
--       { kind = "cell",  sheet = ?string, col = N, row = N }
--       { kind = "range", sheet = ?string, c1, r1, c2, r2 }
--     If ctx returns nil for a cell, treat as 0 / "" depending on context
--     (per common spreadsheet behaviour for blank cells).
--
-- Surface area is intentionally generous; the design goal is "usable for a
-- light-weight rules engine" rather than perfect Excel parity. Where the
-- official semantics are ambiguous we lean towards Google Sheets behaviour.

local M = {}

local sub    = string.sub
local byte   = string.byte
local format = string.format
local concat = table.concat
local floor  = math.floor
local upper  = string.upper
local lower  = string.lower

-- ===== Error sentinels ==================================================
--
-- Wrap as tables so Lua truthiness doesn't accidentally treat them as success.
-- The tostring metamethod lets eval() printable output match the wire format.

local function make_err(name, code)
    local e = setmetatable({ __formula_error = true, code = code, name = name },
        { __tostring = function(self) return self.code end })
    return e
end

local ERR = {
    REF     = make_err("REF",     "#REF!"),
    VALUE   = make_err("VALUE",   "#VALUE!"),
    DIV0    = make_err("DIV0",    "#DIV/0!"),
    NA      = make_err("NA",      "#N/A"),
    NAME    = make_err("NAME",    "#NAME?"),
    NUM     = make_err("NUM",     "#NUM!"),
    NULL    = make_err("NULL",    "#NULL!"),
}
M.errors = ERR

local function is_err(v)
    return type(v) == "table" and v.__formula_error == true
end
M.is_error = is_err

-- ===== Cell ref helpers =================================================

local function col_to_index(letters)
    local n = 0
    for i = 1, #letters do
        n = n * 26 + (byte(letters, i) - 64)
    end
    return n
end

local function index_to_col(n)
    if n < 1 then return "?" end
    local s = ""
    while n > 0 do
        local r = (n - 1) % 26
        s = string.char(65 + r) .. s
        n = (n - 1 - r) / 26
    end
    return s
end
M.col_to_index = col_to_index
M.index_to_col = index_to_col

-- ===== Lexer ============================================================

local function lex(src)
    local toks = {}
    local i, n = 1, #src
    while i <= n do
        local c = byte(src, i)
        if c == 32 or c == 9 or c == 10 or c == 13 then
            i = i + 1
        elseif (c >= 48 and c <= 57) or (c == 46 and byte(src, i + 1) and byte(src, i + 1) >= 48 and byte(src, i + 1) <= 57) then
            local s = i
            while i <= n do
                local b = byte(src, i)
                if (b >= 48 and b <= 57) or b == 46 then i = i + 1 else break end
            end
            if byte(src, i) == 101 or byte(src, i) == 69 then
                i = i + 1
                if byte(src, i) == 43 or byte(src, i) == 45 then i = i + 1 end
                while i <= n do
                    local b = byte(src, i)
                    if b >= 48 and b <= 57 then i = i + 1 else break end
                end
            end
            local num = tonumber(sub(src, s, i - 1))
            if not num then return nil, "bad number" end
            toks[#toks + 1] = { kind = "num", value = num }
        elseif c == 34 then  -- "double-quoted string"
            local parts, s = {}, i + 1
            i = s
            while i <= n do
                if byte(src, i) == 34 then
                    if byte(src, i + 1) == 34 then
                        parts[#parts + 1] = sub(src, s, i)
                        i = i + 2
                        s = i
                    else
                        parts[#parts + 1] = sub(src, s, i - 1)
                        i = i + 1
                        break
                    end
                else
                    i = i + 1
                end
            end
            toks[#toks + 1] = { kind = "str", value = concat(parts) }
        elseif (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c == 36 then
            -- identifier-like: function name, cell ref, sheet name, $A$1
            local s = i
            i = i + 1
            while i <= n do
                local b = byte(src, i)
                if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57)
                    or b == 95 or b == 36 or b == 46 then
                    i = i + 1
                else break end
            end
            local txt = sub(src, s, i - 1)
            -- Sheet-qualified prefix: foo!REST. We keep the prefix glued.
            if byte(src, i) == 33 then  -- !
                i = i + 1
                local s2 = i
                while i <= n do
                    local b = byte(src, i)
                    if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57)
                        or b == 95 or b == 36 then
                        i = i + 1
                    else break end
                end
                txt = txt .. "!" .. sub(src, s2, i - 1)
            end
            local U = upper(txt)
            if U == "TRUE" then toks[#toks + 1] = { kind = "bool", value = true }
            elseif U == "FALSE" then toks[#toks + 1] = { kind = "bool", value = false }
            else toks[#toks + 1] = { kind = "id", value = txt } end
        elseif c == 60 and byte(src, i + 1) == 61 then
            toks[#toks + 1] = { kind = "<=" }; i = i + 2
        elseif c == 62 and byte(src, i + 1) == 61 then
            toks[#toks + 1] = { kind = ">=" }; i = i + 2
        elseif c == 60 and byte(src, i + 1) == 62 then
            toks[#toks + 1] = { kind = "<>" }; i = i + 2
        elseif c == 43 or c == 45 or c == 42 or c == 47 or c == 94 or c == 38
            or c == 60 or c == 62 or c == 61 or c == 40 or c == 41 or c == 44
            or c == 58 or c == 37 or c == 59 then
            toks[#toks + 1] = { kind = string.char(c) }; i = i + 1
        else
            return nil, "unexpected character at " .. i
        end
    end
    toks[#toks + 1] = { kind = "eof" }
    return toks
end

-- ===== Parser ===========================================================
--
-- AST nodes:
--   { kind = "num",    value = number }
--   { kind = "str",    value = string }
--   { kind = "bool",   value = bool   }
--   { kind = "ref",    sheet, col, row, col_abs?, row_abs? }
--   { kind = "range",  sheet, c1, r1, c2, r2 }
--   { kind = "name",   value = "..." }            -- bare identifier we can't resolve as cell
--   { kind = "binop",  op = "+", lhs, rhs }
--   { kind = "unary",  op = "-", arg }
--   { kind = "call",   name = "...", args = { ... } }

local function parse_cell_ref_text(txt)
    -- Try to parse "A1" / "$A$1" / "Sheet1!B7" into a ref or range node.
    local sheet, rest = txt:match("^([^!]+)!(.+)$")
    if not rest then rest = txt end

    -- Two parts separated by ':' -> range
    local left, right = rest:match("^([^:]+):(.+)$")
    if left then
        local c1, r1, ca1, ra1 = left:match("^(%$?)([A-Za-z]+)(%$?)(%d+)$")
        local c2, r2, ca2, ra2 = right:match("^(%$?)([A-Za-z]+)(%$?)(%d+)$")
        -- The capture order is awkward; redo it cleanly.
        local function split(s)
            local ca, col, ra, row = s:match("^(%$?)([A-Za-z]+)(%$?)(%d+)$")
            if not col then return nil end
            return col_to_index(upper(col)), tonumber(row), ca == "$", ra == "$"
        end
        local lc, lr = split(left)
        local rc, rr = split(right)
        if not lc or not rc then return nil end
        return { kind = "range", sheet = sheet, c1 = lc, r1 = lr, c2 = rc, r2 = rr }
    end

    local ca, col, ra, row = rest:match("^(%$?)([A-Za-z]+)(%$?)(%d+)$")
    if not col then return nil end
    return {
        kind = "ref",
        sheet = sheet,
        col = col_to_index(upper(col)),
        row = tonumber(row),
        col_abs = ca == "$",
        row_abs = ra == "$",
    }
end

local Parser = {}
Parser.__index = Parser

function Parser.new(toks)
    return setmetatable({ toks = toks, pos = 1 }, Parser)
end

function Parser:peek() return self.toks[self.pos] end
function Parser:advance() local t = self.toks[self.pos]; self.pos = self.pos + 1; return t end

function Parser:expect(kind)
    local t = self.toks[self.pos]
    if t.kind ~= kind then
        error("formula: expected '" .. kind .. "' got '" .. tostring(t.kind) .. "'")
    end
    self.pos = self.pos + 1
    return t
end

-- Precedence climb table.
local PREC = {
    [":"]  = 80,
    ["^"]  = 70,
    ["*"]  = 60, ["/"] = 60,
    ["+"]  = 50, ["-"] = 50,
    ["&"]  = 40,
    ["="]  = 30, ["<>"] = 30, ["<"] = 30, [">"] = 30, ["<="] = 30, [">="] = 30,
}
local RIGHT_ASSOC = { ["^"] = true }

function Parser:parse_primary()
    local t = self:peek()
    if t.kind == "num" then self:advance(); return { kind = "num", value = t.value }
    elseif t.kind == "str" then self:advance(); return { kind = "str", value = t.value }
    elseif t.kind == "bool" then self:advance(); return { kind = "bool", value = t.value }
    elseif t.kind == "-" then
        self:advance(); local rhs = self:parse_expr(75)
        return { kind = "unary", op = "-", arg = rhs }
    elseif t.kind == "+" then
        self:advance(); return self:parse_expr(75)
    elseif t.kind == "(" then
        self:advance(); local e = self:parse_expr(0); self:expect(")"); return e
    elseif t.kind == "id" then
        self:advance()
        -- Function call?
        if self:peek().kind == "(" then
            self:advance()
            local args = {}
            if self:peek().kind ~= ")" then
                while true do
                    args[#args + 1] = self:parse_expr(0)
                    if self:peek().kind == "," or self:peek().kind == ";" then
                        self:advance()
                    else break end
                end
            end
            self:expect(")")
            return { kind = "call", name = upper(t.value), args = args }
        end
        -- Cell ref / range / named?
        local node = parse_cell_ref_text(t.value)
        if node then return node end
        return { kind = "name", value = t.value }
    end
    error("formula: unexpected token '" .. tostring(t.kind) .. "'")
end

function Parser:parse_expr(min_prec)
    local lhs = self:parse_primary()
    while true do
        local t = self:peek()
        local p = PREC[t.kind]
        if not p or p < min_prec then break end
        local op = self:advance().kind
        local next_min = RIGHT_ASSOC[op] and p or (p + 1)
        local rhs = self:parse_expr(next_min)
        lhs = { kind = "binop", op = op, lhs = lhs, rhs = rhs }
    end
    return lhs
end

function M.parse(text)
    if type(text) ~= "string" then return nil, "formula must be a string" end
    -- Strip leading '=' if present.
    if sub(text, 1, 1) == "=" then text = sub(text, 2) end
    local toks, err = lex(text)
    if not toks then return nil, err end
    local p = Parser.new(toks)
    local ok, ast_or_err = pcall(p.parse_expr, p, 0)
    if not ok then return nil, tostring(ast_or_err) end
    if p:peek().kind ~= "eof" then return nil, "trailing tokens after expression" end
    return ast_or_err
end

-- ===== Coercion helpers =================================================

local function to_number(v)
    if is_err(v) then return v end
    if v == nil then return 0 end
    if type(v) == "number" then return v end
    if type(v) == "boolean" then return v and 1 or 0 end
    if type(v) == "string" then
        local n = tonumber(v)
        if n then return n end
        return ERR.VALUE
    end
    return ERR.VALUE
end

local function to_string(v)
    if is_err(v) then return v end
    if v == nil then return "" end
    if type(v) == "boolean" then return v and "TRUE" or "FALSE" end
    if type(v) == "number" then
        if v == floor(v) and math.abs(v) < 1e15 then return tostring(floor(v)) end
        return tostring(v)
    end
    return tostring(v)
end

local function to_bool(v)
    if is_err(v) then return v end
    if v == nil then return false end
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then
        local u = upper(v)
        if u == "TRUE" then return true end
        if u == "FALSE" then return false end
        return ERR.VALUE
    end
    return ERR.VALUE
end

-- ===== Range materialization ============================================

local function expand_range(node, ctx)
    -- Returns a flat list of values for SUM/AVG/etc.
    local out = {}
    local r1, r2 = math.min(node.r1, node.r2), math.max(node.r1, node.r2)
    local c1, c2 = math.min(node.c1, node.c2), math.max(node.c1, node.c2)
    for r = r1, r2 do
        for c = c1, c2 do
            local cell = { kind = "cell", sheet = node.sheet, col = c, row = r }
            local v = ctx:get(cell)
            out[#out + 1] = v
        end
    end
    return out
end

-- ===== Evaluator ========================================================

local eval_node  -- forward

local function eval_arg_list(args, ctx)
    local out = {}
    for i = 1, #args do
        local v = eval_node(args[i], ctx)
        out[i] = v
    end
    return out
end

-- Flatten a value list so range nodes contribute their cells. Useful for
-- "aggregate" functions like SUM that want a stream of scalars.
local function flatten_for_agg(args, ctx)
    local out = {}
    for i = 1, #args do
        local node = args[i]
        if node.kind == "range" then
            local list = expand_range(node, ctx)
            for j = 1, #list do out[#out + 1] = list[j] end
        else
            out[#out + 1] = eval_node(node, ctx)
        end
    end
    return out
end

-- ===== Function library =================================================

local FUNCS = {}

local function need_args(name, args, n)
    if #args < n then error("#N/A:" .. name .. " needs " .. n .. " args") end
end

local function numeric_only(list)
    -- Drop blanks/strings/bools for aggregation, propagate errors.
    local out = {}
    for i = 1, #list do
        local v = list[i]
        if is_err(v) then return v end
        if type(v) == "number" then out[#out + 1] = v
        elseif type(v) == "string" then
            local n = tonumber(v); if n then out[#out + 1] = n end
        elseif type(v) == "boolean" then
            out[#out + 1] = v and 1 or 0
        end
    end
    return out
end

FUNCS.SUM = function(_args, ctx, raw)
    local list = numeric_only(flatten_for_agg(raw, ctx))
    if is_err(list) then return list end
    local s = 0; for i = 1, #list do s = s + list[i] end; return s
end
FUNCS.AVG = function(_, ctx, raw)
    local list = numeric_only(flatten_for_agg(raw, ctx))
    if is_err(list) then return list end
    if #list == 0 then return ERR.DIV0 end
    local s = 0; for i = 1, #list do s = s + list[i] end
    return s / #list
end
FUNCS.AVERAGE = FUNCS.AVG
FUNCS.MIN = function(_, ctx, raw)
    local list = numeric_only(flatten_for_agg(raw, ctx))
    if is_err(list) then return list end
    if #list == 0 then return 0 end
    local m = list[1]; for i = 2, #list do if list[i] < m then m = list[i] end end
    return m
end
FUNCS.MAX = function(_, ctx, raw)
    local list = numeric_only(flatten_for_agg(raw, ctx))
    if is_err(list) then return list end
    if #list == 0 then return 0 end
    local m = list[1]; for i = 2, #list do if list[i] > m then m = list[i] end end
    return m
end
FUNCS.COUNT = function(_, ctx, raw)
    local list = flatten_for_agg(raw, ctx)
    local c = 0
    for i = 1, #list do
        if type(list[i]) == "number" then c = c + 1
        elseif type(list[i]) == "string" and tonumber(list[i]) then c = c + 1 end
    end
    return c
end
FUNCS.COUNTA = function(_, ctx, raw)
    local list = flatten_for_agg(raw, ctx)
    local c = 0
    for i = 1, #list do if list[i] ~= nil and list[i] ~= "" then c = c + 1 end end
    return c
end

FUNCS.IF = function(args)
    need_args("IF", args, 2)
    local cond = to_bool(args[1])
    if is_err(cond) then return cond end
    if cond then return args[2] else return args[3] end
end
FUNCS.AND = function(args)
    for i = 1, #args do
        local b = to_bool(args[i]); if is_err(b) then return b end
        if not b then return false end
    end
    return true
end
FUNCS.OR = function(args)
    for i = 1, #args do
        local b = to_bool(args[i]); if is_err(b) then return b end
        if b then return true end
    end
    return false
end
FUNCS.NOT = function(args)
    local b = to_bool(args[1]); if is_err(b) then return b end
    return not b
end
FUNCS.IFERROR = function(args)
    if is_err(args[1]) then return args[2] end
    return args[1]
end

FUNCS.CONCATENATE = function(args)
    local buf = {}
    for i = 1, #args do
        local s = to_string(args[i]); if is_err(s) then return s end
        buf[#buf + 1] = s
    end
    return concat(buf)
end
FUNCS.CONCAT = FUNCS.CONCATENATE

FUNCS.LEFT = function(args)
    local s = to_string(args[1]); if is_err(s) then return s end
    local n = to_number(args[2] or 1); if is_err(n) then return n end
    return sub(s, 1, floor(n))
end
FUNCS.RIGHT = function(args)
    local s = to_string(args[1]); if is_err(s) then return s end
    local n = to_number(args[2] or 1); if is_err(n) then return n end
    n = floor(n); if n <= 0 then return "" end
    return sub(s, -n)
end
FUNCS.MID = function(args)
    local s = to_string(args[1]); if is_err(s) then return s end
    local i = to_number(args[2]); if is_err(i) then return i end
    local n = to_number(args[3]); if is_err(n) then return n end
    return sub(s, floor(i), floor(i) + floor(n) - 1)
end
FUNCS.LEN = function(args)
    local s = to_string(args[1]); if is_err(s) then return s end
    return #s
end
FUNCS.UPPER = function(args) local s = to_string(args[1]); if is_err(s) then return s end; return upper(s) end
FUNCS.LOWER = function(args) local s = to_string(args[1]); if is_err(s) then return s end; return lower(s) end
FUNCS.TRIM  = function(args) local s = to_string(args[1]); if is_err(s) then return s end; return s:match("^%s*(.-)%s*$") end
FUNCS.FIND  = function(args)
    local needle = to_string(args[1]); if is_err(needle) then return needle end
    local hay    = to_string(args[2]); if is_err(hay)    then return hay end
    local start  = floor(to_number(args[3] or 1))
    local p = hay:find(needle, start, true)
    if not p then return ERR.VALUE end
    return p
end
FUNCS.REPLACE = function(args)
    -- REPLACE(old, start, num_chars, new)
    local old = to_string(args[1]); if is_err(old) then return old end
    local start = floor(to_number(args[2]))
    local nch   = floor(to_number(args[3]))
    local new   = to_string(args[4]); if is_err(new) then return new end
    return sub(old, 1, start - 1) .. new .. sub(old, start + nch)
end
FUNCS.SUBSTITUTE = function(args)
    -- SUBSTITUTE(text, old, new, [instance])
    local s = to_string(args[1]); if is_err(s) then return s end
    local old = to_string(args[2]); if is_err(old) then return old end
    local new = to_string(args[3]); if is_err(new) then return new end
    if not args[4] then
        return (s:gsub(old:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0"), new))
    end
    local inst = floor(to_number(args[4]))
    local count = 0
    local pat = old:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    return (s:gsub(pat, function(m)
        count = count + 1
        if count == inst then return new end
        return m
    end))
end

-- VLOOKUP / MATCH / INDEX need the raw range node so we can iterate cells.
FUNCS.VLOOKUP = function(args, ctx, raw)
    -- VLOOKUP(lookup_value, table_array, col_index_num, [range_lookup])
    if #raw < 3 then return ERR.NA end
    local needle = args[1]
    local rng = raw[2]
    if rng.kind ~= "range" then return ERR.VALUE end
    local col_off = floor(to_number(args[3]))
    if col_off < 1 then return ERR.VALUE end
    local r1, r2 = math.min(rng.r1, rng.r2), math.max(rng.r1, rng.r2)
    local c1     = math.min(rng.c1, rng.c2)
    for r = r1, r2 do
        local v = ctx:get({ kind = "cell", sheet = rng.sheet, col = c1, row = r })
        if v == needle then
            return ctx:get({ kind = "cell", sheet = rng.sheet, col = c1 + col_off - 1, row = r })
        end
    end
    return ERR.NA
end
FUNCS.MATCH = function(args, ctx, raw)
    -- MATCH(value, lookup_array, [match_type])
    local needle = args[1]
    local rng = raw[2]
    if rng.kind ~= "range" then return ERR.VALUE end
    local list = expand_range(rng, ctx)
    for i = 1, #list do if list[i] == needle then return i end end
    return ERR.NA
end
FUNCS.INDEX = function(args, ctx, raw)
    -- INDEX(array, row, [col])
    local rng = raw[1]
    if rng.kind ~= "range" then return ERR.VALUE end
    local r = floor(to_number(args[2]))
    local c = args[3] and floor(to_number(args[3])) or 1
    local r1 = math.min(rng.r1, rng.r2)
    local c1 = math.min(rng.c1, rng.c2)
    return ctx:get({ kind = "cell", sheet = rng.sheet, col = c1 + c - 1, row = r1 + r - 1 })
end

-- Math.
FUNCS.ROUND = function(args)
    local v = to_number(args[1]); if is_err(v) then return v end
    local d = args[2] and floor(to_number(args[2])) or 0
    local m = 10 ^ d
    return floor(v * m + 0.5) / m
end
FUNCS.CEILING = function(args)
    local v = to_number(args[1]); if is_err(v) then return v end
    local s = args[2] and to_number(args[2]) or 1
    return math.ceil(v / s) * s
end
FUNCS.FLOOR = function(args)
    local v = to_number(args[1]); if is_err(v) then return v end
    local s = args[2] and to_number(args[2]) or 1
    return floor(v / s) * s
end
FUNCS.MOD = function(args)
    local a, b = to_number(args[1]), to_number(args[2])
    if is_err(a) then return a end; if is_err(b) then return b end
    if b == 0 then return ERR.DIV0 end
    return a - floor(a / b) * b
end
FUNCS.ABS   = function(args) local v = to_number(args[1]); if is_err(v) then return v end; return math.abs(v) end
FUNCS.SQRT  = function(args) local v = to_number(args[1]); if is_err(v) then return v end; if v < 0 then return ERR.NUM end; return math.sqrt(v) end
FUNCS.POWER = function(args) local a, b = to_number(args[1]), to_number(args[2]); if is_err(a) then return a end; if is_err(b) then return b end; return a ^ b end
FUNCS.EXP   = function(args) local v = to_number(args[1]); if is_err(v) then return v end; return math.exp(v) end
FUNCS.LN    = function(args) local v = to_number(args[1]); if is_err(v) then return v end; if v <= 0 then return ERR.NUM end; return math.log(v) end
FUNCS.LOG   = function(args)
    local v = to_number(args[1]); if is_err(v) then return v end
    if v <= 0 then return ERR.NUM end
    if args[2] then
        local b = to_number(args[2]); if is_err(b) then return b end
        return math.log(v) / math.log(b)
    end
    return math.log(v) / math.log(10)
end
FUNCS.SIN = function(args) local v = to_number(args[1]); if is_err(v) then return v end; return math.sin(v) end
FUNCS.COS = function(args) local v = to_number(args[1]); if is_err(v) then return v end; return math.cos(v) end
FUNCS.TAN = function(args) local v = to_number(args[1]); if is_err(v) then return v end; return math.tan(v) end
FUNCS.PI  = function() return math.pi end
FUNCS.RAND = function() return math.random() end
FUNCS.RANDBETWEEN = function(args)
    local lo, hi = floor(to_number(args[1])), floor(to_number(args[2]))
    return math.random(lo, hi)
end

-- Date helpers. The traditional spreadsheet "date serial" is days since
-- 1899-12-30 to match Excel/Sheets, but os.time can't represent dates that
-- early on Windows (the C runtime clamps below 1970). We use a Julian-Day-
-- based serial conversion to stay portable: every serial -> proleptic
-- Gregorian Y/M/D, then back via the same math. Numeric value of the serial
-- is preserved as "days since 1899-12-30" so legacy formulas keep working.

local SERIAL_BASE_JDN = 2415019  -- JDN of 1899-12-30

local function gregorian_to_jdn(y, m, d)
    -- Standard Fliegel-Van Flandern conversion.
    local a = floor((14 - m) / 12)
    local yy = y + 4800 - a
    local mm = m + 12 * a - 3
    return d + floor((153 * mm + 2) / 5) + 365 * yy + floor(yy / 4)
        - floor(yy / 100) + floor(yy / 400) - 32045
end

local function jdn_to_gregorian(jdn)
    local a = jdn + 32044
    local b = floor((4 * a + 3) / 146097)
    local c = a - floor((146097 * b) / 4)
    local d = floor((4 * c + 3) / 1461)
    local e = c - floor((1461 * d) / 4)
    local m = floor((5 * e + 2) / 153)
    local day   = e - floor((153 * m + 2) / 5) + 1
    local month = m + 3 - 12 * floor(m / 10)
    local year  = 100 * b + d - 4800 + floor(m / 10)
    return year, month, day
end

local function serial_to_ymd(serial)
    local jdn = SERIAL_BASE_JDN + floor(serial)
    local y, mo, d = jdn_to_gregorian(jdn)
    return { year = y, month = mo, day = d }
end

local function ymd_to_serial(y, mo, d)
    return gregorian_to_jdn(y, mo, d) - SERIAL_BASE_JDN
end

FUNCS.DATE = function(args)
    local y = floor(to_number(args[1]))
    local m = floor(to_number(args[2]))
    local d = floor(to_number(args[3]))
    return ymd_to_serial(y, m, d)
end
FUNCS.TODAY = function()
    local tab = os.date("*t")
    return ymd_to_serial(tab.year, tab.month, tab.day)
end
FUNCS.NOW = function()
    local tab = os.date("*t")
    local day_serial = ymd_to_serial(tab.year, tab.month, tab.day)
    return day_serial + (tab.hour * 3600 + tab.min * 60 + tab.sec) / 86400
end
FUNCS.YEAR    = function(args) return serial_to_ymd(to_number(args[1])).year end
FUNCS.MONTH   = function(args) return serial_to_ymd(to_number(args[1])).month end
FUNCS.DAY     = function(args) return serial_to_ymd(to_number(args[1])).day end
FUNCS.WEEKDAY = function(args)
    -- 1899-12-30 was a Saturday -> serial 0 maps to wday 7 in Sun=1 scheme.
    local s = floor(to_number(args[1]))
    return ((s + 6) % 7) + 1
end

-- ===== Node evaluation ==================================================

local function eval_ref(node, ctx)
    local v = ctx:get(node)
    if v == nil then return 0 end  -- blank treated as 0 for math contexts
    return v
end

local function apply_binop(op, a, b)
    if is_err(a) then return a end
    if is_err(b) then return b end
    if op == "&" then
        local sa, sb = to_string(a), to_string(b)
        if is_err(sa) then return sa end; if is_err(sb) then return sb end
        return sa .. sb
    end
    if op == "=" then return a == b end
    if op == "<>" then return a ~= b end
    if op == "<" or op == ">" or op == "<=" or op == ">=" then
        local na, nb = to_number(a), to_number(b)
        if is_err(na) then return na end; if is_err(nb) then return nb end
        if op == "<" then return na < nb
        elseif op == ">" then return na > nb
        elseif op == "<=" then return na <= nb
        else return na >= nb end
    end
    local na, nb = to_number(a), to_number(b)
    if is_err(na) then return na end; if is_err(nb) then return nb end
    if op == "+" then return na + nb
    elseif op == "-" then return na - nb
    elseif op == "*" then return na * nb
    elseif op == "/" then if nb == 0 then return ERR.DIV0 end; return na / nb
    elseif op == "^" then return na ^ nb
    end
    return ERR.VALUE
end

eval_node = function(node, ctx)
    local k = node.kind
    if k == "num" or k == "str" or k == "bool" then return node.value
    elseif k == "ref" then return eval_ref(node, ctx)
    elseif k == "range" then return node  -- aggregator handles it; returning range as scalar is #VALUE!
    elseif k == "name" then return ERR.NAME
    elseif k == "unary" then
        local v = eval_node(node.arg, ctx)
        if is_err(v) then return v end
        local n = to_number(v); if is_err(n) then return n end
        return -n
    elseif k == "binop" then
        local a = eval_node(node.lhs, ctx)
        local b = eval_node(node.rhs, ctx)
        -- Treat raw range nodes outside aggregations as errors.
        if type(a) == "table" and a.kind == "range" then return ERR.VALUE end
        if type(b) == "table" and b.kind == "range" then return ERR.VALUE end
        return apply_binop(node.op, a, b)
    elseif k == "call" then
        local fn = FUNCS[node.name]
        if not fn then return ERR.NAME end
        local values = eval_arg_list(node.args, ctx)
        -- Special functions need access to the raw arg AST for range awareness.
        local ok, ret = pcall(fn, values, ctx, node.args)
        if not ok then
            local s = tostring(ret)
            if s:match("#N/A") then return ERR.NA end
            return ERR.VALUE
        end
        return ret
    end
    return ERR.VALUE
end

function M.eval(text, ctx)
    if ctx == nil or type(ctx.get) ~= "function" then
        return ERR.VALUE
    end
    local ast, err = M.parse(text)
    if not ast then return ERR.NAME end
    return eval_node(ast, ctx)
end

-- Generic version: evaluate any AST against a generic context table.
function M.evaluate(ast, ctx)
    if type(ast) ~= "table" then return ERR.VALUE end
    if ctx == nil or type(ctx.get) ~= "function" then return ERR.VALUE end
    return eval_node(ast, ctx)
end

-- ===== Engine: cell store + dependency graph ============================
--
-- A self-contained spreadsheet model. Cells are addressed by their A1
-- string ("A1", "AB23", "Sheet1!B7"). set() accepts either a raw value
-- (number/string/bool) or a formula string starting with '='. get()
-- returns the evaluated (cached) value. dependencies() returns the cell
-- addresses a given formula reads from. recalculate() walks dirty cells
-- in topological order and recomputes only what is needed.
--
-- This is intentionally light on Excel-feature parity: no array formulas,
-- no volatile/iterative recalc, single workspace. The goal is "good
-- enough for config-driven rule sheets and small data tables".

local Engine = {}
Engine.__index = Engine

local function parse_addr(addr)
    -- "Sheet1!A1" / "A1" -> sheet, col, row
    local sheet, rest = addr:match("^([^!]+)!(.+)$")
    if not rest then rest = addr end
    local col, row = rest:match("^%$?([A-Za-z]+)%$?(%d+)$")
    if not col then return nil end
    return sheet, col_to_index(upper(col)), tonumber(row)
end

local function fmt_addr(sheet, col, row)
    local a = index_to_col(col) .. tostring(row)
    if sheet then return sheet .. "!" .. a end
    return a
end

local function key_of(sheet, col, row)
    return (sheet or "") .. ":" .. col .. ":" .. row
end

-- Walk an AST collecting cell-address dependencies. Returns a list of
-- plain "A1" / "Sheet!A1" strings, deduplicated.
local function walk_deps(node, sheet_default, out, seen)
    if type(node) ~= "table" then return end
    local k = node.kind
    if k == "ref" then
        local a = fmt_addr(node.sheet or sheet_default, node.col, node.row)
        if not seen[a] then seen[a] = true; out[#out + 1] = a end
    elseif k == "range" then
        local r1, r2 = math.min(node.r1, node.r2), math.max(node.r1, node.r2)
        local c1, c2 = math.min(node.c1, node.c2), math.max(node.c1, node.c2)
        for r = r1, r2 do
            for c = c1, c2 do
                local a = fmt_addr(node.sheet or sheet_default, c, r)
                if not seen[a] then seen[a] = true; out[#out + 1] = a end
            end
        end
    elseif k == "binop" then
        walk_deps(node.lhs, sheet_default, out, seen)
        walk_deps(node.rhs, sheet_default, out, seen)
    elseif k == "unary" then
        walk_deps(node.arg, sheet_default, out, seen)
    elseif k == "call" then
        for _, a in ipairs(node.args) do walk_deps(a, sheet_default, out, seen) end
    end
end

function M.engine()
    local self = setmetatable({
        cells     = {},   -- key -> { value, formula, ast, deps, rdeps }
        dirty     = {},   -- key -> true
    }, Engine)
    self.ctx = {
        get = function(_, ref)
            -- ref shape: { kind = "cell", sheet, col, row }
            local k = key_of(ref.sheet, ref.col, ref.row)
            local cell = self.cells[k]
            if not cell then return nil end
            return cell.value
        end,
    }
    return self
end

function Engine:_get_cell(addr, create)
    local sheet, col, row = parse_addr(addr)
    if not col then return nil, "bad address: " .. tostring(addr) end
    local k = key_of(sheet, col, row)
    local c = self.cells[k]
    if not c and create then
        c = { sheet = sheet, col = col, row = row, value = nil, formula = nil,
              ast = nil, deps = {}, rdeps = {} }
        self.cells[k] = c
    end
    return c, k
end

function Engine:set(addr, value)
    local cell, k = self:_get_cell(addr, true)
    if not cell then return nil, k end
    -- Detach previous reverse-deps.
    for _, dep_key in ipairs(cell.deps) do
        local target = self.cells[dep_key]
        if target then
            for i = #target.rdeps, 1, -1 do
                if target.rdeps[i] == k then table.remove(target.rdeps, i) end
            end
        end
    end
    cell.deps = {}
    cell.ast = nil
    cell.formula = nil

    if type(value) == "string" and sub(value, 1, 1) == "=" then
        local ast, err = M.parse(value)
        if not ast then
            cell.value = ERR.NAME
            return nil, err
        end
        cell.formula = value
        cell.ast     = ast
        -- Resolve dependencies and create reverse links so we know what to
        -- mark dirty when a source cell changes.
        local list, seen = {}, {}
        walk_deps(ast, cell.sheet, list, seen)
        for _, dep_addr in ipairs(list) do
            local dep_cell, dep_key = self:_get_cell(dep_addr, true)
            cell.deps[#cell.deps + 1] = dep_key
            dep_cell.rdeps[#dep_cell.rdeps + 1] = k
        end
        cell.value = nil  -- lazy evaluation; recalc on demand
        self.dirty[k] = true
    else
        cell.value = value
    end

    -- Anything depending on us is now dirty.
    self:_mark_dirty_chain(k)
    return true
end

function Engine:_mark_dirty_chain(start_key)
    local stack = { start_key }
    while #stack > 0 do
        local k = table.remove(stack)
        local c = self.cells[k]
        if c then
            for _, r in ipairs(c.rdeps) do
                if not self.dirty[r] then
                    self.dirty[r] = true
                    stack[#stack + 1] = r
                end
            end
        end
    end
end

function Engine:formula(addr)
    local cell = self:_get_cell(addr, false)
    return cell and cell.formula or nil
end

function Engine:get(addr)
    local cell, k = self:_get_cell(addr, false)
    if not cell then return nil end
    if cell.ast and (self.dirty[k] or cell.value == nil) then
        self:_recalc_one(k)
    end
    return cell.value
end

function Engine:dependencies(addr)
    local cell = self:_get_cell(addr, false)
    if not cell or not cell.ast then return {} end
    local out = {}
    for i, dep_key in ipairs(cell.deps) do
        local dc = self.cells[dep_key]
        out[i] = fmt_addr(dc.sheet, dc.col, dc.row)
    end
    return out
end

function Engine:_recalc_one(k)
    local cell = self.cells[k]
    if not cell or not cell.ast then return end
    -- Recurse into dirty deps first so we always read fresh values.
    for _, dep_key in ipairs(cell.deps) do
        if self.dirty[dep_key] then self:_recalc_one(dep_key) end
    end
    cell.value = eval_node(cell.ast, self.ctx)
    self.dirty[k] = nil
end

function Engine:recalculate()
    -- Snapshot keys to a stable list to avoid mutating during iteration.
    local todo = {}
    for k in pairs(self.dirty) do todo[#todo + 1] = k end
    for _, k in ipairs(todo) do self:_recalc_one(k) end
end

-- ===== CSV import / export ==============================================
--
-- Minimal RFC 4180-ish: comma-separated, double-quoted fields, escape "" for
-- a literal quote, CRLF or LF row terminators. Values that look like
-- numbers become numbers, values starting with '=' become formulas, the
-- rest stay as strings.

local function parse_csv(text)
    -- Returns array of row arrays.
    local rows, row = {}, {}
    local i, n = 1, #text
    local field = {}
    local in_quotes = false
    while i <= n do
        local c = sub(text, i, i)
        if in_quotes then
            if c == '"' then
                if sub(text, i + 1, i + 1) == '"' then
                    field[#field + 1] = '"'; i = i + 2
                else
                    in_quotes = false; i = i + 1
                end
            else
                field[#field + 1] = c; i = i + 1
            end
        else
            if c == '"' then
                in_quotes = true; i = i + 1
            elseif c == "," then
                row[#row + 1] = concat(field); field = {}
                i = i + 1
            elseif c == "\r" then
                row[#row + 1] = concat(field); field = {}
                rows[#rows + 1] = row; row = {}
                i = (sub(text, i + 1, i + 1) == "\n") and (i + 2) or (i + 1)
            elseif c == "\n" then
                row[#row + 1] = concat(field); field = {}
                rows[#rows + 1] = row; row = {}
                i = i + 1
            else
                field[#field + 1] = c; i = i + 1
            end
        end
    end
    if #field > 0 or #row > 0 then
        row[#row + 1] = concat(field)
        rows[#rows + 1] = row
    end
    return rows
end

local function csv_quote(s)
    -- Quote only if needed (contains comma, quote, or CR/LF).
    if s:find("[,\"\r\n]") then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

function Engine:from_csv(text, opts)
    opts = opts or {}
    local rows = parse_csv(text)
    local start_row = opts.start_row or 1
    local start_col = opts.start_col or 1
    for r, row in ipairs(rows) do
        for c, raw in ipairs(row) do
            if raw ~= "" then
                local addr = index_to_col(start_col + c - 1) .. tostring(start_row + r - 1)
                local n = tonumber(raw)
                if n ~= nil and not raw:find("^=") then
                    self:set(addr, n)
                elseif sub(raw, 1, 1) == "=" then
                    self:set(addr, raw)
                else
                    self:set(addr, raw)
                end
            end
        end
    end
    self:recalculate()
end

function Engine:to_csv(opts)
    -- Emit the bounding rectangle of non-empty cells. Formulas export as
    -- their evaluated value by default; pass { raw = true } to emit '='.
    opts = opts or {}
    local raw_mode = opts.raw == true
    local min_c, min_r, max_c, max_r
    for _, cell in pairs(self.cells) do
        if cell.value ~= nil or cell.formula then
            if not min_c or cell.col < min_c then min_c = cell.col end
            if not max_c or cell.col > max_c then max_c = cell.col end
            if not min_r or cell.row < min_r then min_r = cell.row end
            if not max_r or cell.row > max_r then max_r = cell.row end
        end
    end
    if not min_c then return "" end
    local out = {}
    for r = min_r, max_r do
        local row = {}
        for c = min_c, max_c do
            local k = key_of(nil, c, r)
            local cell = self.cells[k]
            local v = ""
            if cell then
                if raw_mode and cell.formula then v = cell.formula
                elseif cell.value ~= nil then
                    if is_err(cell.value) then v = cell.value.code
                    else v = to_string(cell.value) end
                end
            end
            row[#row + 1] = csv_quote(v)
        end
        out[#out + 1] = concat(row, ",")
    end
    return concat(out, "\n")
end

M.Engine = Engine

return M
