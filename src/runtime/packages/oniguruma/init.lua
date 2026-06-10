-- oniguruma -- Onigmo / Oniguruma regex bindings via onig.dll.
--
-- Public surface:
--   oniguruma.available()             -- true if onig.dll loaded
--   oniguruma.version()               -- "x.y.z"
--   oniguruma.compile(pattern, opts?) -> regex
--     opts: {
--       encoding = "utf8"|"ascii"|"utf16le"|"sjis"  (default "utf8"),
--       syntax   = "ruby"|"perl"|"posix-ere"|"posix-bre"|"java"  (default "ruby"),
--       options  = { i, m, s, x, ignore_case, multiline, dotall, extend,
--                    find_longest, find_not_empty }
--     }
--
-- regex:
--   :match(s, start?)                 -> match table or nil
--                                          match[0] = whole, match[1..n] = groups,
--                                          match.start = byte start (1-based),
--                                          match.finish = byte end inclusive
--   :find(s, init?)                   -> start, finish, {captures} | nil
--   :gmatch(s)                        -> iterator -> match table
--   :gsub(s, repl, max?)              -> new_string, count
--   :split(s, max?)                   -> { piece, ... }
--   :test(s)                          -> bool
--
-- Module-level convenience: compile() + run in one call.
--   oniguruma.match(pat, s, opts?)
--   oniguruma.find(pat, s, opts?)
--   oniguruma.gmatch(pat, s, opts?)
--   oniguruma.gsub(pat, s, repl, max?, opts?)
--   oniguruma.split(pat, s, max?, opts?)
--   oniguruma.test(pat, s, opts?)

local M = {}

ffi.cdef[[
typedef int             OnigCodePoint;
typedef unsigned char   OnigUChar;
typedef unsigned int    OnigOptionType;
typedef void           *OnigEncoding;
typedef void           *OnigSyntaxType;

typedef struct re_pattern_buffer  OnigRegex;
typedef struct re_pattern_buffer *regex_t;

typedef struct {
    int   num_regs;
    int  *beg;
    int  *end;
    void *history_root;
} OnigRegion;

typedef struct {
    int  enc_alloc;
    int  case_fold_flag;
    void *pattern_enc;
    void *target_enc;
    OnigSyntaxType *syntax;
    OnigOptionType option;
} OnigCompileInfo;

typedef struct OnigErrorInfo {
    void       *enc;
    OnigUChar  *par;
    OnigUChar  *par_end;
} OnigErrorInfo;

extern OnigEncoding   OnigEncodingASCII;
extern OnigEncoding   OnigEncodingUTF8;
extern OnigEncoding   OnigEncodingUTF16_LE;
extern OnigEncoding   OnigEncodingSJIS;
extern OnigSyntaxType OnigSyntaxRuby;
extern OnigSyntaxType OnigSyntaxPerl;
extern OnigSyntaxType OnigSyntaxPosixExtended;
extern OnigSyntaxType OnigSyntaxPosixBasic;
extern OnigSyntaxType OnigSyntaxJava;
extern OnigSyntaxType OnigSyntaxDefault;

int  onig_initialize(OnigEncoding encs[], int n);
int  onig_end(void);
const char *onig_version(void);

int  onig_new(regex_t *reg, const OnigUChar *pattern, const OnigUChar *pattern_end,
              OnigOptionType option, OnigEncoding enc, OnigSyntaxType *syntax,
              OnigErrorInfo *einfo);
void onig_free(regex_t reg);

int  onig_search(regex_t reg, const OnigUChar *str, const OnigUChar *end,
                 const OnigUChar *start, const OnigUChar *range,
                 OnigRegion *region, OnigOptionType option);

OnigRegion *onig_region_new(void);
void        onig_region_free(OnigRegion *region, int free_self);
void        onig_region_clear(OnigRegion *region);

int  onig_error_code_to_str(OnigUChar *err_buf, int err_code, OnigErrorInfo *einfo);

int  onig_number_of_names(regex_t reg);
int  onig_name_to_backref_number(regex_t reg, const OnigUChar *name,
                                 const OnigUChar *name_end, OnigRegion *region);

typedef int (*OnigForeachNameCb)(const OnigUChar *name, const OnigUChar *name_end,
                                 int ngroup_num, int *group_nums, regex_t reg, void *arg);
int  onig_foreach_name(regex_t reg, OnigForeachNameCb cb, void *arg);
]]

-- ===== Option bits (from onig.h / onigmo.h) ==============================
-- These are the standard ONIG_OPTION_* values, stable across upstream
-- versions.

local ONIG_OPTION_NONE             = 0
local ONIG_OPTION_IGNORECASE       = 1
local ONIG_OPTION_EXTEND           = 2
local ONIG_OPTION_MULTILINE        = 4
local ONIG_OPTION_SINGLELINE       = 8   -- "dotall" in PCRE-speak; onig flips the naming
local ONIG_OPTION_FIND_LONGEST     = 16
local ONIG_OPTION_FIND_NOT_EMPTY   = 32
local ONIG_OPTION_NEGATE_SINGLELINE= 64

-- Onig's SINGLELINE means '.' matches anything including \n; MULTILINE
-- (confusingly named) makes ^/$ match at line boundaries. We expose
-- the Perl-style names externally.

-- ===== Lazy DLL loader ===================================================

local _lib, _load_err, _inited

local function load_lib()
    if _lib then return _lib end
    if _load_err then return nil end
    local names = {}
    local env_dll = os.getenv("LUAVM_ONIG_DLL")
    if env_dll and #env_dll > 0 then names[#names + 1] = env_dll end
    names[#names + 1] = "onig"
    names[#names + 1] = "onig.dll"
    names[#names + 1] = "onigmo"
    names[#names + 1] = "onigmo.dll"
    names[#names + 1] = "libonig"
    names[#names + 1] = "libonig-5.dll"
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then _lib = lib; return lib end
    end
    _load_err = "oniguruma: onig.dll not found. Set LUAVM_ONIG_DLL or drop onig.dll next to LuaVM."
    return nil
end

local function ensure_init(L)
    if _inited then return end
    -- onig_initialize with a single encoding (UTF-8) is the recommended
    -- minimum. NULL/0 also works for libs configured with all encodings
    -- enabled; we be defensive and pass UTF-8.
    local arr = ffi.new("OnigEncoding[1]")
    arr[0] = L.OnigEncodingUTF8
    L.onig_initialize(arr, 1)
    _inited = true
end

function M.available()
    return load_lib() ~= nil
end

local function require_lib()
    local L = load_lib()
    if L == nil then error(_load_err, 3) end
    ensure_init(L)
    return L
end

function M.version()
    local L = load_lib()
    if L == nil then return "?" end
    local s = L.onig_version()
    return s ~= nil and ffi.string(s) or "?"
end

-- ===== Helpers ===========================================================

local function encoding_for(name)
    if name == nil or name == "utf8" or name == "utf-8" then return "OnigEncodingUTF8" end
    if name == "ascii" then return "OnigEncodingASCII" end
    if name == "utf16le" or name == "utf-16le" then return "OnigEncodingUTF16_LE" end
    if name == "sjis" or name == "shift-jis" then return "OnigEncodingSJIS" end
    error("oniguruma: unknown encoding '" .. tostring(name) .. "'", 3)
end

local function syntax_for(name)
    if name == nil or name == "ruby" then return "OnigSyntaxRuby" end
    if name == "perl" then return "OnigSyntaxPerl" end
    if name == "posix-ere" or name == "ere" then return "OnigSyntaxPosixExtended" end
    if name == "posix-bre" or name == "bre" then return "OnigSyntaxPosixBasic" end
    if name == "java" then return "OnigSyntaxJava" end
    if name == "default" then return "OnigSyntaxDefault" end
    error("oniguruma: unknown syntax '" .. tostring(name) .. "'", 3)
end

local function parse_option_flags(t)
    local opts = ONIG_OPTION_NONE
    if t == nil then return opts end
    for k, v in pairs(t) do
        if v then
            if     k == "i" or k == "ignore_case" then
                opts = opts + ONIG_OPTION_IGNORECASE
            elseif k == "m" or k == "multiline" then
                opts = opts + ONIG_OPTION_MULTILINE
            elseif k == "s" or k == "dotall" then
                -- PCRE-style dotall = Onig SINGLELINE.
                opts = opts + ONIG_OPTION_SINGLELINE
            elseif k == "x" or k == "extend" then
                opts = opts + ONIG_OPTION_EXTEND
            elseif k == "find_longest" then
                opts = opts + ONIG_OPTION_FIND_LONGEST
            elseif k == "find_not_empty" then
                opts = opts + ONIG_OPTION_FIND_NOT_EMPTY
            else
                error("oniguruma: unknown option flag '" .. tostring(k) .. "'", 3)
            end
        end
    end
    return opts
end

local function format_error(L, code)
    local buf = ffi.new("OnigUChar[256]")
    local n = L.onig_error_code_to_str(buf, code, nil)
    if n <= 0 then return "onig error " .. tostring(code) end
    return ffi.string(buf, n)
end

-- ===== Regex object ======================================================

local Regex = {}
Regex.__index = Regex

local function new_regex_from(L, pattern, opts)
    opts = opts or {}
    local enc_field = encoding_for(opts.encoding)
    local syn_field = syntax_for(opts.syntax)
    local option_bits = parse_option_flags(opts.options)
    local reg_pp = ffi.new("regex_t[1]")
    local einfo  = ffi.new("OnigErrorInfo")
    local enc = L[enc_field]
    local syn = L[syn_field]
    local rc = L.onig_new(
        reg_pp,
        ffi.cast("const OnigUChar *", pattern),
        ffi.cast("const OnigUChar *", pattern) + #pattern,
        option_bits, enc, ffi.cast("OnigSyntaxType *", syn), einfo)
    if rc ~= 0 then
        error("oniguruma.compile: " .. format_error(L, rc), 3)
    end
    return setmetatable({
        _lib     = L,
        _reg     = ffi.gc(reg_pp[0], L.onig_free),
        _pattern = pattern,
        _options = option_bits,
    }, Regex)
end

function M.compile(pattern, opts)
    local L = require_lib()
    return new_regex_from(L, pattern, opts)
end

-- Run a single onig_search and decode the OnigRegion into a match table.
local function do_search(self, s, pos)
    local L = self._lib
    local region = L.onig_region_new()
    if region == nil then error("oniguruma: region_new returned nil", 3) end
    region = ffi.gc(region, function(r) L.onig_region_free(r, 1) end)

    local base = ffi.cast("const OnigUChar *", s)
    local start_off = (pos or 1) - 1
    if start_off < 0 then start_off = 0 end
    local start = base + start_off
    local stop  = base + #s
    local rc = L.onig_search(self._reg, base, stop, start, stop, region, 0)
    if rc < 0 then
        if rc == -1 then return nil end  -- ONIG_MISMATCH
        error("oniguruma: " .. format_error(L, rc), 3)
    end
    local n = tonumber(region.num_regs)
    local result = {}
    -- region.beg/end are int arrays of length num_regs; index 0 is whole match.
    -- `end` is a Lua keyword so we access via bracket notation.
    local b0 = tonumber(region.beg[0])
    local e0 = tonumber(region["end"][0])
    result[0] = s:sub(b0 + 1, e0)
    for i = 1, n - 1 do
        local bi = tonumber(region.beg[i])
        local ei = tonumber(region["end"][i])
        if bi < 0 or ei < 0 then
            result[i] = false  -- unmatched optional group
        else
            result[i] = s:sub(bi + 1, ei)
        end
    end
    result.start  = b0 + 1
    result.finish = e0
    return result
end

function Regex:match(s, init)  return do_search(self, s, init) end

function Regex:find(s, init)
    local m = do_search(self, s, init)
    if m == nil then return nil end
    local caps = {}
    local i = 1
    while m[i] ~= nil do caps[i] = m[i]; i = i + 1 end
    return m.start, m.finish, caps
end

function Regex:test(s) return do_search(self, s, 1) ~= nil end

local function iter_matches(self, s)
    local pos = 1
    local slen = #s
    return function()
        if pos > slen + 1 then return nil end
        local m = do_search(self, s, pos)
        if m == nil then return nil end
        if m.finish < m.start then
            pos = m.start + 1  -- zero-length match -- advance to avoid infinite loop
        else
            pos = m.finish + 1
        end
        return m
    end
end

function Regex:gmatch(s) return iter_matches(self, s) end

-- $0..$9 in a replacement string.
local function expand_repl(repl, m)
    return (repl:gsub("%$(%d)", function(d)
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
        local m = do_search(self, s, pos)
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

function Regex:split(s, max)
    local parts = {}
    local np    = 0
    local pos   = 1
    local slen  = #s
    max = max or math.huge
    while np < max - 1 and pos <= slen + 1 do
        local m = do_search(self, s, pos)
        if m == nil then break end
        if m.finish < m.start and m.start == pos then
            pos = pos + 1
        else
            np = np + 1; parts[np] = s:sub(pos, m.start - 1)
            pos = m.finish + 1
            if pos < m.start then pos = m.start + 1 end
        end
    end
    np = np + 1; parts[np] = s:sub(pos)
    return parts
end

-- ===== Module-level shortcuts ============================================

function M.match(pat, s, opts)  return M.compile(pat, opts):match(s)  end
function M.find(pat, s, opts)   return M.compile(pat, opts):find(s)   end
function M.gmatch(pat, s, opts) return M.compile(pat, opts):gmatch(s) end
function M.test(pat, s, opts)   return M.compile(pat, opts):test(s)   end

function M.gsub(pat, s, repl, max, opts)
    return M.compile(pat, opts):gsub(s, repl, max)
end

function M.split(pat, s, max, opts)
    return M.compile(pat, opts):split(s, max)
end

return M
