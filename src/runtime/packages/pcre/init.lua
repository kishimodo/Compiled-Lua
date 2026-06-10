-- pcre -- PCRE2 (8-bit) regex via the pcre2-8.dll.
--
-- The DLL is loaded lazily: requiring the module never fails. Calling
-- compile() when the DLL is absent raises a clear error so the runtime
-- keeps functioning if PCRE2 isn't installed.
--
-- Public surface (object):
--   pcre.compile(pattern, flags?) -> regex
--   pcre.available()              -> bool
--   regex:match(s, init?)         -> match table or nil
--                                    match[0] = full match,
--                                    match[1..n] = numbered groups,
--                                    match.named = { name = text, ... },
--                                    match.start / match.finish = byte range
--   regex:find(s, init?)          -> start, end, captures-table | nil
--   regex:gmatch(s)               -> iterator -> match table
--   regex:gsub(s, repl, max?)     -> new_string, count
--   regex:split(s, max?)          -> { piece, piece, ... }
--   regex:test(s)                 -> bool
--
-- Public surface (module-level convenience that compiles + runs):
--   pcre.match(pat, s, flags?)
--   pcre.find(pat, s, flags?)
--   pcre.gmatch(pat, s, flags?)
--   pcre.gsub(pat, s, repl, max?, flags?)
--   pcre.split(pat, s, max?, flags?)
--   pcre.test(pat, s, flags?)
--
-- Flags string letters:
--   i  case-insensitive       (PCRE2_CASELESS)
--   m  multiline (^/$ match line boundaries)  (PCRE2_MULTILINE)
--   s  dotall (. matches \n)  (PCRE2_DOTALL)
--   x  extended (ignore whitespace + #-comments)  (PCRE2_EXTENDED)
--   U  ungreedy (invert lazy/greedy default)  (PCRE2_UNGREEDY)
--   u  treat input as UTF-8 (PCRE2_UTF | PCRE2_UCP)
--
-- The legacy alias regex:find_all(s) -> { match, ... } is retained for
-- compatibility with earlier callers; new code should prefer :gmatch.

local ffi = ffi

local M = {}

-- ===== FFI cdefs =======================================================
-- Names are namespaced with `pcre2_` so they can't collide with any
-- other module's cdefs (ffi.cdef is process-global).

ffi.cdef [[
typedef struct pcre2_real_code_8     pcre2_code_8;
typedef struct pcre2_real_match_data_8 pcre2_match_data_8;
typedef struct pcre2_real_general_context_8 pcre2_general_context_8;
typedef struct pcre2_real_compile_context_8 pcre2_compile_context_8;
typedef struct pcre2_real_match_context_8   pcre2_match_context_8;

pcre2_code_8 *pcre2_compile_8(
    const unsigned char *pattern, size_t length, uint32_t options,
    int *errorcode, size_t *erroroffset, pcre2_compile_context_8 *ccontext);

void pcre2_code_free_8(pcre2_code_8 *code);

pcre2_match_data_8 *pcre2_match_data_create_from_pattern_8(
    const pcre2_code_8 *code, pcre2_general_context_8 *gcontext);

void pcre2_match_data_free_8(pcre2_match_data_8 *match_data);

int pcre2_match_8(
    const pcre2_code_8 *code, const unsigned char *subject, size_t length,
    size_t startoffset, uint32_t options,
    pcre2_match_data_8 *match_data, pcre2_match_context_8 *mcontext);

size_t *pcre2_get_ovector_pointer_8(pcre2_match_data_8 *match_data);
uint32_t pcre2_get_ovector_count_8(pcre2_match_data_8 *match_data);

int pcre2_get_error_message_8(int errorcode, unsigned char *buffer, size_t bufflen);

/* Named-group introspection. PCRE2 stores name records as a packed array
 * of fixed-width entries; pcre2_pattern_info_8 with PCRE2_INFO_NAMETABLE
 * returns a pointer to the first entry. Each entry is 2 bytes of group
 * index (big-endian) + the NUL-terminated name. */
int pcre2_pattern_info_8(const pcre2_code_8 *code, uint32_t what, void *where);
]]

-- ===== Option bits (from pcre2.h) =======================================

local PCRE2_CASELESS   = 0x00000008
local PCRE2_MULTILINE  = 0x00000400
local PCRE2_DOTALL     = 0x00000020
local PCRE2_EXTENDED   = 0x00000080
local PCRE2_UTF        = 0x00080000
local PCRE2_UCP        = 0x00020000
local PCRE2_UNGREEDY   = 0x00040000

local PCRE2_INFO_NAMECOUNT     = 17
local PCRE2_INFO_NAMEENTRYSIZE = 18
local PCRE2_INFO_NAMETABLE     = 19

-- PCRE2_ERROR_NOMATCH = -1; positive return = number of captured groups + 1.

-- ===== Lazy DLL loader =================================================

local _lib
local _load_error
local function load_lib()
    if _lib ~= nil then return _lib end
    if _load_error then return nil end
    local ok, lib = pcall(ffi.load, "pcre2-8")
    if not ok then
        _load_error = "pcre2-8.dll not available: " .. tostring(lib)
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
        error("pcre: " .. (_load_error or "pcre2-8.dll not loaded"), 3)
    end
    return lib
end

-- ===== Helpers =========================================================

local function parse_flags(flags)
    local opts = 0
    if flags == nil or flags == "" then return opts end
    for i = 1, #flags do
        local c = flags:sub(i, i)
        if c == "i" then
            opts = opts + PCRE2_CASELESS
        elseif c == "m" then
            opts = opts + PCRE2_MULTILINE
        elseif c == "s" then
            opts = opts + PCRE2_DOTALL
        elseif c == "x" then
            opts = opts + PCRE2_EXTENDED
        elseif c == "U" then
            opts = opts + PCRE2_UNGREEDY
        elseif c == "u" then
            opts = opts + PCRE2_UTF + PCRE2_UCP
        else
            error("pcre: unknown flag '" .. c .. "'", 3)
        end
    end
    return opts
end

local _err_buf = ffi.new("unsigned char[256]")
local function format_error(lib, code)
    local n = lib.pcre2_get_error_message_8(code, _err_buf, 256)
    if n <= 0 then return "pcre2 error " .. tostring(code) end
    return ffi.string(_err_buf, n)
end

-- Read the (group-index -> group-name) table once at compile time.
local function extract_name_map(lib, code)
    local count_buf = ffi.new("uint32_t[1]")
    local size_buf  = ffi.new("uint32_t[1]")
    if lib.pcre2_pattern_info_8(code, PCRE2_INFO_NAMECOUNT, count_buf) ~= 0 then
        return nil
    end
    local count = tonumber(count_buf[0])
    if count == 0 then return nil end
    if lib.pcre2_pattern_info_8(code, PCRE2_INFO_NAMEENTRYSIZE, size_buf) ~= 0 then
        return nil
    end
    local entry_size = tonumber(size_buf[0])
    local table_ptr_buf = ffi.new("unsigned char *[1]")
    if lib.pcre2_pattern_info_8(code, PCRE2_INFO_NAMETABLE, table_ptr_buf) ~= 0 then
        return nil
    end
    local tbl = table_ptr_buf[0]
    if tbl == nil then return nil end
    local map = {}
    for i = 0, count - 1 do
        local off = i * entry_size
        -- 16-bit big-endian group index, then NUL-terminated name.
        local idx = (tbl[off] * 256) + tbl[off + 1]
        local name = ffi.string(tbl + off + 2)
        map[#map + 1] = { idx = idx, name = name }
    end
    return map
end

-- ===== Regex object ====================================================

local Regex = {}
Regex.__index = Regex

local function new_regex(code, lib, flags_str)
    -- Wrap PCRE2 code pointer with a GC finalizer so it frees on collection.
    local code_gc = ffi.gc(code, lib.pcre2_code_free_8)
    return setmetatable({
        _code     = code_gc,
        _lib      = lib,
        _flags    = flags_str or "",
        _name_map = extract_name_map(lib, code_gc),
    }, Regex)
end

-- Run a single match attempt starting at byte position `pos` (1-based).
-- Returns either the match table or nil.
local function do_match(self, s, pos)
    local lib = self._lib
    local md  = lib.pcre2_match_data_create_from_pattern_8(self._code, nil)
    if md == nil then error("pcre: out of memory", 3) end
    md = ffi.gc(md, lib.pcre2_match_data_free_8)

    local start_off = (pos or 1) - 1
    if start_off < 0 then start_off = 0 end

    local rc = lib.pcre2_match_8(
        self._code,
        ffi.cast("const unsigned char *", s),
        #s,
        start_off,
        0,
        md,
        nil)
    if rc < 0 then
        if rc == -1 then return nil end
        error("pcre: " .. format_error(lib, rc), 3)
    end

    local ovec = lib.pcre2_get_ovector_pointer_8(md)
    local n_groups = rc  -- whole match counts as one
    local result = {}
    -- [0] = whole match, [1..n-1] = numbered groups
    do
        local s0 = tonumber(ovec[0])
        local e0 = tonumber(ovec[1])
        result[0] = s:sub(s0 + 1, e0)
    end
    for i = 1, n_groups - 1 do
        local sN = tonumber(ovec[i * 2])
        local eN = tonumber(ovec[i * 2 + 1])
        if sN < 0 or eN < 0 then
            result[i] = false  -- unmatched optional group
        else
            result[i] = s:sub(sN + 1, eN)
        end
    end
    -- Build the .named table from the precomputed name map.
    if self._name_map then
        local named = {}
        for _, entry in ipairs(self._name_map) do
            named[entry.name] = result[entry.idx]
        end
        result.named = named
    end
    result.start  = tonumber(ovec[0]) + 1
    result.finish = tonumber(ovec[1])
    -- legacy aliases retained for older callers
    result._start  = result.start
    result._finish = result.finish
    return result
end

function Regex:match(s, init)
    return do_match(self, s, init)
end

function Regex:find(s, init)
    local m = do_match(self, s, init)
    if m == nil then return nil end
    -- Collect numbered captures into a list (skipping [0]).
    local caps = {}
    local i = 1
    while m[i] ~= nil do caps[i] = m[i]; i = i + 1 end
    return m.start, m.finish, caps
end

function Regex:test(s)
    return do_match(self, s, 1) ~= nil
end

-- Generic iterator used by both gmatch (yields the match table) and
-- find_all (collects them into a list).
local function iter_matches(self, s)
    local pos  = 1
    local slen = #s
    return function()
        if pos > slen + 1 then return nil end
        local m = do_match(self, s, pos)
        if m == nil then return nil end
        if m.finish < m.start then
            -- zero-length match: advance by one byte to avoid infinite loop
            pos = m.start + 1
        else
            pos = m.finish + 1
        end
        return m
    end
end

function Regex:gmatch(s)
    return iter_matches(self, s)
end

-- Legacy alias.
function Regex:find_all(s)
    local list = {}
    for m in iter_matches(self, s) do list[#list + 1] = m end
    return list
end

-- $0..$9 and ${name} expansion inside a replacement string.
local function expand_repl(repl, m)
    -- First handle ${name} so it doesn't get clobbered by the $N pass.
    local r1 = repl:gsub("%${([^}]+)}", function(name)
        if m.named then
            local v = m.named[name]
            if v == false or v == nil then return "" end
            return v
        end
        return ""
    end)
    return (r1:gsub("%$(%d)", function(d)
        local idx = tonumber(d)
        if idx == 0 then return m[0] end
        local v = m[idx]
        if v == false or v == nil then return "" end
        return v
    end))
end

function Regex:gsub(s, repl, max)
    local parts = {}
    local np    = 0
    local pos   = 1
    local count = 0
    local slen  = #s
    max = max or math.huge
    while pos <= slen + 1 and count < max do
        local m = do_match(self, s, pos)
        if m == nil then break end
        if m.start > pos then
            np = np + 1; parts[np] = s:sub(pos, m.start - 1)
        end
        local out
        if type(repl) == "function" then
            local v = repl(m)
            out = v == nil and m[0] or tostring(v)
        elseif type(repl) == "table" then
            local v = repl[m[0]]
            out = v == nil and m[0] or tostring(v)
        else
            out = expand_repl(repl, m)
        end
        np = np + 1; parts[np] = out
        count = count + 1
        if m.finish < m.start then
            -- zero-length: copy the byte we skip past
            if m.start <= slen then
                np = np + 1; parts[np] = s:sub(m.start, m.start)
            end
            pos = m.start + 1
        else
            pos = m.finish + 1
        end
    end
    if pos <= slen then
        np = np + 1; parts[np] = s:sub(pos)
    end
    return table.concat(parts), count
end

-- Legacy alias.
function Regex:replace(s, repl)
    return self:gsub(s, repl)
end

function Regex:split(s, max)
    local parts = {}
    local np    = 0
    local pos   = 1
    local slen  = #s
    max = max or math.huge
    while np < max - 1 and pos <= slen + 1 do
        local m = do_match(self, s, pos)
        if m == nil then break end
        if m.finish < m.start and m.start == pos then
            -- zero-length match at the very start of the remaining input;
            -- skip a byte to keep moving
            pos = pos + 1
        else
            local piece = s:sub(pos, m.start - 1)
            np = np + 1; parts[np] = piece
            pos = m.finish + 1
            if pos < m.start then pos = m.start + 1 end
        end
    end
    -- final tail
    np = np + 1; parts[np] = s:sub(pos)
    return parts
end

-- ===== Module entry =====================================================

function M.compile(pattern, flags)
    local lib  = require_lib()
    local opts = parse_flags(flags)
    local err_code = ffi.new("int[1]")
    local err_off  = ffi.new("size_t[1]")
    local code = lib.pcre2_compile_8(
        ffi.cast("const unsigned char *", pattern),
        #pattern,
        opts,
        err_code,
        err_off,
        nil)
    if code == nil then
        error(string.format("pcre.compile: %s (offset %d)",
            format_error(lib, err_code[0]),
            tonumber(err_off[0])), 2)
    end
    return new_regex(code, lib, flags)
end

-- ===== Module-level convenience: compile + run in one call ==============

function M.match(pat, s, flags)  return M.compile(pat, flags):match(s)  end
function M.find(pat, s, flags)   return M.compile(pat, flags):find(s)   end
function M.gmatch(pat, s, flags) return M.compile(pat, flags):gmatch(s) end
function M.test(pat, s, flags)   return M.compile(pat, flags):test(s)   end

function M.gsub(pat, s, repl, max, flags)
    return M.compile(pat, flags):gsub(s, repl, max)
end

function M.split(pat, s, max, flags)
    return M.compile(pat, flags):split(s, max)
end

return M
