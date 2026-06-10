-- apperror -- structured error type with cause chain, stack, and fields.
--
-- Public surface:
--   apperror.new(message_or_table)        -> err
--   apperror.wrap(err, msg, fields?)      -> err   (wraps err as cause)
--   apperror.is(err, kind)                -> bool  (walks cause chain)
--   apperror.match(err, patterns)         -> result (pattern-match on kind)
--   apperror.try(fn, ...)                 -> ok, err_or_result    (pcall wrapper)
--   err:message()                         -> string
--   err:cause()                           -> err or nil
--   err:stack()                           -> string
--   err:fields()                          -> table
--   err:kind()                            -> string or nil
--   err:root_cause()                      -> deepest err
--   err:tostring()                        -> pretty multi-line render
--   err:to_table()                        -> serializable structure
--   tostring(err)                         -> pretty render via metatable
--
-- Storage layout: internal data lives under leading-underscore keys so the
-- public method names (message, cause, stack, fields, kind) don't collide
-- with field lookups. Lua resolves err.field BEFORE __index, so a stored
-- `message` string would shadow the `:message()` method -- we sidestep
-- that with `_message`, `_cause`, etc.

local M = {}

-- ===== Metatable =======================================================

local Err = {}
Err.__index = Err

local function is_apperror(x)
    return type(x) == "table" and x._is_apperror == true
end

M.is_apperror = is_apperror

-- ===== Constructors ====================================================

local function capture_stack(skip)
    -- A clean traceback minus the top frames belonging to us (new/wrap).
    if not debug or not debug.traceback then return "" end
    return debug.traceback("", skip + 1):gsub("^\nstack traceback:\n", "")
end

local function make(message, kind, fields, cause, stack)
    return setmetatable({
        _message     = message,
        _kind        = kind,
        _fields      = fields or {},
        _cause       = cause,
        _stack       = stack or capture_stack(3),
        _is_apperror = true,
    }, Err)
end

function M.new(arg)
    -- Polymorphic constructor:
    --   new("just a message")
    --   new{message="...", kind="io.timeout", fields={...}}
    if type(arg) == "string" then
        return make(arg, nil, nil, nil, capture_stack(2))
    elseif type(arg) == "table" then
        return make(arg.message or "error", arg.kind, arg.fields, arg.cause,
            arg.stack or capture_stack(2))
    else
        error("apperror.new: expected string or table, got " .. type(arg))
    end
end

function M.wrap(err, msg, fields)
    -- Wrap a lower-level error so the outer message can add context. If err
    -- isn't an apperror, lift it into one so the chain is uniform.
    if not is_apperror(err) then err = M.new(tostring(err)) end
    local kind = fields and fields.kind or nil
    local f = {}
    if fields then
        for k, v in pairs(fields) do
            if k ~= "kind" then f[k] = v end
        end
    end
    return make(msg, kind, f, err, capture_stack(2))
end

-- ===== Predicates / matching ============================================

function M.is(err, kind)
    -- Walk the cause chain; return true on the first match.
    -- `kind` may be an exact string ("io.timeout") or a hierarchical prefix
    -- ("io"), where prefix matching follows dotted-segment boundaries.
    while is_apperror(err) do
        local k = err._kind
        if k == kind then return true end
        if k and (k == kind or k:sub(1, #kind + 1) == kind .. ".") then
            return true
        end
        err = err._cause
    end
    return false
end

-- Match a (string-kind, handler) table against err's chain. Returns the
-- handler's result. Supports a default key "_" applied when no kind hits.
--
--   apperror.match(err, {
--     ["io.timeout"]   = function(e) ... end,
--     ["io"]           = function(e) ... end,    -- prefix
--     _                = function(e) ... end,    -- default
--   })
function M.match(err, patterns)
    if not is_apperror(err) then err = M.new(tostring(err)) end
    -- Walk the chain so a wrapped low-level kind is still routable.
    local cur = err
    while is_apperror(cur) do
        local k = cur._kind
        if k then
            if patterns[k] then return patterns[k](err) end
            local best_prefix, best_handler = nil, nil
            for pk, h in pairs(patterns) do
                if pk ~= "_" and type(pk) == "string" and k:sub(1, #pk + 1) == pk .. "." then
                    if not best_prefix or #pk > #best_prefix then
                        best_prefix, best_handler = pk, h
                    end
                end
            end
            if best_handler then return best_handler(err) end
        end
        cur = cur._cause
    end
    if patterns._ then return patterns._(err) end
    return nil
end

-- ===== Accessors ========================================================

function Err:message() return self._message end
function Err:cause()   return self._cause end
function Err:stack()   return self._stack end
function Err:fields()  return self._fields end
function Err:kind()    return self._kind end

function Err:root_cause()
    local cur = self
    while cur._cause do cur = cur._cause end
    return cur
end

-- Collect every kind appearing in the chain. Useful for logging context.
function Err:kinds()
    local out = {}
    local cur = self
    while is_apperror(cur) do
        if cur._kind then out[#out + 1] = cur._kind end
        cur = cur._cause
    end
    return out
end

-- ===== Field helpers ===================================================

function Err:with(extra)
    -- Returns a NEW err with extra fields merged in. Avoids surprising
    -- mutation of the source error -- a logger should be able to add request
    -- context without poisoning the original for later handlers.
    local f = {}
    for k, v in pairs(self._fields) do f[k] = v end
    for k, v in pairs(extra) do f[k] = v end
    return make(self._message, self._kind, f, self._cause, self._stack)
end

function Err:get(k)
    -- Walk the chain so a field set on a wrapped lower-level error is still
    -- findable via the outermost handle.
    local cur = self
    while is_apperror(cur) do
        if cur._fields and cur._fields[k] ~= nil then return cur._fields[k] end
        cur = cur._cause
    end
    return nil
end

-- ===== Serialization ===================================================

local function fields_to_string(t)
    if not t or not next(t) then return "" end
    local parts = {}
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = t[k]
        local s
        if type(v) == "string" then s = string.format("%q", v)
        elseif type(v) == "table" then s = "{...}"
        else s = tostring(v) end
        parts[#parts + 1] = k .. "=" .. s
    end
    return " {" .. table.concat(parts, " ") .. "}"
end

function Err:tostring()
    -- Multi-line cause chain with each layer indented and prefixed.
    local lines = {}
    local cur = self
    local depth = 0
    while is_apperror(cur) do
        local prefix = depth == 0 and "" or (string.rep("  ", depth) .. "caused by: ")
        local kind_pref = cur._kind and ("[" .. cur._kind .. "] ") or ""
        lines[#lines + 1] = prefix .. kind_pref .. cur._message .. fields_to_string(cur._fields)
        cur = cur._cause
        depth = depth + 1
    end
    if depth > 0 and self._stack and self._stack ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = self._stack
    end
    return table.concat(lines, "\n")
end

Err.__tostring = function(self) return Err.tostring(self) end

-- A flat, jsonable representation. Cause becomes nested. Useful for
-- shoving through the `log` package.
function Err:to_table()
    local out = {
        message = self._message,
        kind    = self._kind,
        fields  = self._fields,
        stack   = self._stack,
    }
    if self._cause then
        if is_apperror(self._cause) then out.cause = self._cause:to_table()
        else out.cause = { message = tostring(self._cause) } end
    end
    return out
end

-- ===== Convenience: try() ==============================================
--
-- A pcall wrapper that lifts a thrown non-apperror into an apperror so
-- callers can match() / is() against a single shape regardless of source.

function M.try(fn, ...)
    local results = { pcall(fn, ...) }
    if results[1] then
        table.remove(results, 1)
        return true, table.unpack(results)
    else
        local err = results[2]
        if is_apperror(err) then return false, err end
        return false, M.new({ message = tostring(err), kind = "runtime" })
    end
end

-- Convert any pcall-style error into an apperror without re-pcalling.
function M.from(raw, kind)
    if is_apperror(raw) then return raw end
    return M.new({ message = tostring(raw), kind = kind })
end

-- Raise an apperror. We use error() with the apperror table; downstream
-- pcall handlers see the table directly and can match on it.
function M.raise(arg)
    error(M.new(arg), 2)
end

-- ===== Kinds builder ===================================================
--
-- A tiny helper for projects that want a sealed set of error kinds without
-- maintaining string constants by hand. Returns a table of constructors.
--
--   local Errs = apperror.kinds("myapp", {
--     NotFound   = "not_found",
--     BadInput   = "bad_input",
--     Timeout    = "timeout",
--   })
--   error(Errs.NotFound("user 42 missing", { id = 42 }))
--   apperror.is(err, "myapp.not_found")  -- true

function M.kinds(prefix, table_of_kinds)
    local out = {}
    for ctor_name, kind in pairs(table_of_kinds) do
        local fq = prefix .. "." .. kind
        out[ctor_name] = function(message, fields)
            local f = {}
            if fields then for k, v in pairs(fields) do f[k] = v end end
            return M.new({ message = message, kind = fq, fields = f })
        end
    end
    return out
end

return M
