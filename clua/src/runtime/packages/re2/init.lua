-- re2 -- RE2 regex via the system re2.dll.
--
-- RE2 is a finite-automaton matcher: linear-time in the input, no
-- backreferences, no lookaround. The trade-off is predictable performance
-- on adversarial patterns.
--
-- The DLL is loaded lazily, mirroring the pcre package. require()-ing the
-- module never fails; compile() raises a descriptive error when re2.dll
-- isn't present.
--
-- Note: RE2 does not ship a stable C ABI in its upstream release. Most
-- Windows builds expose a small C shim (commonly named cre2 or re2_c)
-- that compiles + matches against a void* opaque handle. We cdef the
-- canonical "cre2" surface (https://github.com/marcomaggi/cre2) since
-- that's the de facto C shim used across language bindings; if a host
-- ships re2.dll exporting the same names directly, that works too.
--
-- Public surface (mirrors pcre):
--   re2.compile(pattern, flags?)  -> regex
--   re2.available()               -> bool
--   regex:match(s, pos?)          -> { full, group1, ... } or nil
--   regex:find_all(s)             -> { match_obj, ... }
--   regex:replace(s, repl)        -> string, count
--   regex:split(s, opts?)         -> { piece, ... }

local ffi = ffi

local M = {}

-- ===== cdef ============================================================
-- Names prefixed to avoid clashes with anything else cdef'd in the VM.

ffi.cdef [[
typedef struct cre2_regexp_t   cre2_regexp_t;
typedef struct cre2_options_t  cre2_options_t;

typedef struct cre2_string_t {
    const char *data;
    int         length;
} cre2_string_t;

cre2_options_t *cre2_opt_new(void);
void            cre2_opt_delete(cre2_options_t *opt);
void            cre2_opt_set_case_sensitive(cre2_options_t *opt, int b);
void            cre2_opt_set_dot_nl(cre2_options_t *opt, int b);
void            cre2_opt_set_one_line(cre2_options_t *opt, int b);
void            cre2_opt_set_log_errors(cre2_options_t *opt, int b);
void            cre2_opt_set_utf8(cre2_options_t *opt, int b);

cre2_regexp_t *cre2_new(const char *pattern, int pattern_len, const cre2_options_t *opt);
void           cre2_delete(cre2_regexp_t *re);

int   cre2_error_code(const cre2_regexp_t *re);
const char *cre2_error_string(const cre2_regexp_t *re);

int   cre2_num_capturing_groups(const cre2_regexp_t *re);

int   cre2_match(const cre2_regexp_t *re,
                 const char *text, int textlen,
                 int startpos, int endpos,
                 int anchor,
                 cre2_string_t *match, int nmatch);
]]

-- ===== Lazy DLL loader =================================================

local _lib
local _load_error
local function load_lib()
    if _lib ~= nil then return _lib end
    if _load_error then return nil end
    local ok, lib = pcall(ffi.load, "re2")
    if not ok then
        -- some distros call the shim "cre2"
        ok, lib = pcall(ffi.load, "cre2")
    end
    if not ok then
        _load_error = "re2.dll / cre2.dll not available: " .. tostring(lib)
        return nil
    end
    _lib = lib
    return lib
end

function M.available()
    return load_lib() ~= nil
end

local function require_lib()
    local lib = load_lib()
    if lib == nil then
        error("re2: " .. (_load_error or "re2.dll not loaded"), 3)
    end
    return lib
end

-- ===== Flag parsing ====================================================

local function parse_flags(lib, flags)
    local opt = ffi.gc(lib.cre2_opt_new(), lib.cre2_opt_delete)
    if opt == nil then error("re2: out of memory", 3) end
    lib.cre2_opt_set_log_errors(opt, 0)        -- silence stderr
    lib.cre2_opt_set_case_sensitive(opt, 1)    -- default
    if flags then
        for i = 1, #flags do
            local c = flags:sub(i, i)
            if c == "i" then
                lib.cre2_opt_set_case_sensitive(opt, 0)
            elseif c == "s" then
                -- dotall: '.' matches \n
                lib.cre2_opt_set_dot_nl(opt, 1)
            elseif c == "m" then
                -- multiline default is on in RE2; "one_line" off keeps ^/$ as line anchors
                lib.cre2_opt_set_one_line(opt, 0)
            elseif c == "u" then
                lib.cre2_opt_set_utf8(opt, 1)
            else
                error("re2: unknown flag '" .. c .. "'", 3)
            end
        end
    end
    return opt
end

-- ===== Regex object ====================================================

local Regex = {}
Regex.__index = Regex

local function new_regex(re, lib, ngroups)
    return setmetatable({
        _re      = ffi.gc(re, lib.cre2_delete),
        _lib     = lib,
        _ngroups = ngroups,
    }, Regex)
end

-- anchor enum:  0 = UNANCHORED, 1 = ANCHOR_START, 2 = ANCHOR_BOTH
local function do_match(self, s, pos)
    local lib   = self._lib
    local slen  = #s
    local start = (pos or 1) - 1
    if start < 0 then start = 0 end
    if start > slen then return nil end
    local nmatch = self._ngroups + 1
    local matches = ffi.new("cre2_string_t[?]", nmatch)
    local data    = ffi.cast("const char *", s)
    local rc = lib.cre2_match(self._re, data, slen, start, slen, 0, matches, nmatch)
    if rc == 0 then return nil end
    local result = {}
    for i = 0, nmatch - 1 do
        local m = matches[i]
        if m.data == nil then
            result[i + 1] = false
        else
            -- m.data points into the input buffer; convert to a Lua string
            result[i + 1] = ffi.string(m.data, m.length)
        end
    end
    -- recover 1-based start/finish from pointer arithmetic
    local m0 = matches[0]
    local start_off
    if m0.data == nil then
        start_off = start
    else
        start_off = tonumber(ffi.cast("intptr_t", m0.data) - ffi.cast("intptr_t", data))
    end
    result._start  = start_off + 1
    result._finish = start_off + m0.length
    return result
end

function Regex:match(s, pos) return do_match(self, s, pos) end

function Regex:find_all(s)
    local results = {}
    local pos = 1
    local slen = #s
    while pos <= slen + 1 do
        local m = do_match(self, s, pos)
        if m == nil then break end
        results[#results + 1] = m
        if m._finish < m._start then
            pos = m._start + 1
        else
            pos = m._finish + 1
        end
    end
    return results
end

function Regex:replace(s, repl)
    local parts = {}
    local np    = 0
    local pos   = 1
    local count = 0
    local slen  = #s
    while pos <= slen + 1 do
        local m = do_match(self, s, pos)
        if m == nil then break end
        if m._start > pos then
            np = np + 1; parts[np] = s:sub(pos, m._start - 1)
        end
        local out
        if type(repl) == "function" then
            out = repl(m) or ""
        else
            out = (repl:gsub("%$(%d)", function(d)
                local v = m[tonumber(d) + 1]
                if v == false or v == nil then return "" end
                return v
            end))
        end
        np = np + 1; parts[np] = out
        count = count + 1
        if m._finish < m._start then
            if m._start <= slen then
                np = np + 1; parts[np] = s:sub(m._start, m._start)
            end
            pos = m._start + 1
        else
            pos = m._finish + 1
        end
    end
    if pos <= slen then
        np = np + 1; parts[np] = s:sub(pos)
    end
    return table.concat(parts), count
end

function Regex:split(s, opts)
    opts = opts or {}
    local max   = opts.limit or math.huge
    local empty = opts.allow_empty
    local parts = {}
    local np    = 0
    local pos   = 1
    local slen  = #s
    while np < max - 1 and pos <= slen + 1 do
        local m = do_match(self, s, pos)
        if m == nil then break end
        if m._finish < m._start and m._start == pos then
            pos = pos + 1
        else
            local piece = s:sub(pos, m._start - 1)
            if empty or #piece > 0 then
                np = np + 1; parts[np] = piece
            end
            pos = m._finish + 1
            if pos < m._start then pos = m._start + 1 end
        end
    end
    np = np + 1; parts[np] = s:sub(pos)
    return parts
end

-- ===== Module entry =====================================================

function M.compile(pattern, flags)
    local lib  = require_lib()
    local opts = parse_flags(lib, flags)
    local re   = lib.cre2_new(pattern, #pattern, opts)
    if re == nil then error("re2.compile: out of memory", 2) end
    local err = lib.cre2_error_code(re)
    if err ~= 0 then
        local msg = ffi.string(lib.cre2_error_string(re))
        lib.cre2_delete(re)
        error("re2.compile: " .. msg, 2)
    end
    local n = lib.cre2_num_capturing_groups(re)
    return new_regex(re, lib, n)
end

return M
