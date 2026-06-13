-- zip_native -- libzip-backed ZIP reader / writer (native-speed).
--
-- API mirrors the pure-Lua `zip` package surface so callers can swap
-- between them with no code changes:
--
--   zip_native.available()              -- true if libzip.dll loaded
--   zip_native.version()                -- "x.y.z"
--   zip_native.open(path)               -> reader
--   zip_native.create(path, opts?)      -> writer  (opts.truncate=true to overwrite)
--
-- reader:
--   :list()                             -> array of { name, size, csize, mtime, method, crc32 }
--   :read(name_or_index)                -> bytes
--   :extract_all(dest_dir)              -> array of extracted paths
--   :count()                            -> int
--   :close()
--
-- writer:
--   :add_file(name, bytes, opts?)       -- opts: { compression="store"|"deflate", level=6 }
--   :add_path(name, fs_path, opts?)     -- like add_file but reads bytes off disk
--   :close()                            -> bool

local M = {}

ffi.cdef[[
typedef struct zip       zip_t;
typedef struct zip_file  zip_file_t;
typedef struct zip_source zip_source_t;

typedef long long       zip_int64_t;
typedef unsigned long long zip_uint64_t;
typedef int             zip_int32_t;
typedef unsigned int    zip_uint32_t;
typedef unsigned short  zip_uint16_t;

typedef struct {
    zip_uint64_t valid;
    char         name[256];
    zip_uint64_t index;
    zip_uint64_t size;
    zip_uint64_t comp_size;
    long         mtime;       /* time_t */
    zip_uint32_t crc;
    zip_uint16_t comp_method;
    zip_uint16_t encryption_method;
    zip_uint32_t flags;
} zip_stat_t;

zip_t       *zip_open(const char *path, int flags, int *errorp);
int          zip_close(zip_t *archive);
int          zip_discard(zip_t *archive);
const char  *zip_strerror(zip_t *archive);
const char  *zip_error_strerror(void *err);
zip_int64_t  zip_get_num_entries(zip_t *archive, int flags);
const char  *zip_get_name(zip_t *archive, zip_uint64_t index, int flags);
int          zip_stat_index(zip_t *archive, zip_uint64_t index, int flags, zip_stat_t *st);
int          zip_stat(zip_t *archive, const char *name, int flags, zip_stat_t *st);

zip_file_t  *zip_fopen_index(zip_t *archive, zip_uint64_t index, int flags);
zip_file_t  *zip_fopen(zip_t *archive, const char *name, int flags);
zip_int64_t  zip_fread(zip_file_t *file, void *buf, zip_uint64_t nbytes);
int          zip_fclose(zip_file_t *file);

zip_source_t *zip_source_buffer(zip_t *archive, const void *data, zip_uint64_t len, int freep);
zip_source_t *zip_source_file(zip_t *archive, const char *fname,
                              zip_uint64_t start, zip_int64_t len);
void          zip_source_free(zip_source_t *source);

zip_int64_t   zip_file_add(zip_t *archive, const char *name, zip_source_t *source, int flags);
int           zip_set_file_compression(zip_t *archive, zip_uint64_t index,
                                       zip_int32_t method, zip_uint32_t flags);

const char   *zip_libzip_version(void);
]]

-- ===== Flag constants ====================================================

M.ZIP_CREATE     = 1
M.ZIP_EXCL       = 2
M.ZIP_CHECKCONS  = 4
M.ZIP_TRUNCATE   = 8
M.ZIP_RDONLY     = 16

M.ZIP_CM_DEFAULT = -1
M.ZIP_CM_STORE   = 0
M.ZIP_CM_DEFLATE = 8

M.ZIP_FL_OVERWRITE = 0x2000
M.ZIP_FL_ENC_GUESS = 0
M.ZIP_FL_ENC_UTF_8 = 2048

-- ===== Lazy DLL loader ===================================================

local _lib, _load_err

local function load_lib()
    if _lib then return _lib end
    if _load_err then return nil end
    local names = {}
    local env_dll = os.getenv("CLUA_LIBZIP_DLL")
    if env_dll and #env_dll > 0 then names[#names + 1] = env_dll end
    names[#names + 1] = "libzip"
    names[#names + 1] = "libzip.dll"
    names[#names + 1] = "zip"
    names[#names + 1] = "zip.dll"
    names[#names + 1] = "libzip-5.dll"
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then _lib = lib; return lib end
    end
    _load_err = "zip_native: libzip.dll not found. "
        .. "Set CLUA_LIBZIP_DLL or drop libzip.dll next to CLua."
    return nil
end

function M.available()
    return load_lib() ~= nil
end

local function require_lib()
    local L = load_lib()
    if L == nil then error(_load_err, 3) end
    return L
end

function M.version()
    local L = load_lib()
    if L == nil then return "?" end
    local ok, s = pcall(function() return L.zip_libzip_version() end)
    if not ok or s == nil then return "?" end
    return ffi.string(s)
end

-- ===== Helpers ===========================================================

local function check_open(L, err_code, path)
    if err_code == 0 then return end
    -- Without a zip_t we can only stringify the bare code; libzip exports
    -- richer error info but the surface differs across versions.
    error(string.format("zip_native: open '%s' failed (error %d)", tostring(path), err_code), 3)
end

local function zip_error(L, archive, prefix)
    local p = L.zip_strerror(archive)
    local msg = p ~= nil and ffi.string(p) or "unknown libzip error"
    error("zip_native: " .. prefix .. ": " .. msg, 3)
end

local function stat_entry(L, archive, index)
    local st = ffi.new("zip_stat_t")
    if L.zip_stat_index(archive, index, 0, st) ~= 0 then
        zip_error(L, archive, "stat_index")
    end
    local name = L.zip_get_name(archive, index, 0)
    return {
        name        = name ~= nil and ffi.string(name) or "",
        size        = tonumber(st.size),
        csize       = tonumber(st.comp_size),
        compressed  = tonumber(st.comp_size),
        uncompressed = tonumber(st.size),
        mtime       = tonumber(st.mtime),
        method      = tonumber(st.comp_method),
        crc32       = tonumber(st.crc),
        index       = tonumber(st.index),
        is_dir      = (name ~= nil) and (ffi.string(name):sub(-1) == "/") or false,
    }
end

-- Recursive mkdir best-effort via shell (matches pure-Lua zip's approach).
local function ensure_dir(path)
    if path == nil or path == "" or path == "." then return end
    os.execute(string.format('mkdir "%s" 2>nul', path:gsub("/", "\\")))
end

local function dirname(path)
    local p = path:gsub("\\", "/")
    local i = p:find("/[^/]*$")
    if i then return p:sub(1, i - 1) end
    return ""
end

-- Reject archive entry names that would escape the destination directory
-- (Zip-Slip / CWE-22). libzip returns names verbatim from the central
-- directory; an absolute path, drive prefix, or ".." segment must not be
-- written. Raises rather than writing a hostile name.
local function safe_entry_name(name)
    local n = name:gsub("\\", "/")
    if n:sub(1, 1) == "/" or n:match("^%a:") then
        error("zip_native.extract_all: refusing absolute path in entry: " .. name)
    end
    for seg in (n .. "/"):gmatch("([^/]*)/") do
        if seg == ".." then
            error("zip_native.extract_all: refusing path traversal ('..') in entry: " .. name)
        end
    end
end

-- ===== Reader object =====================================================

local Reader = {}
Reader.__index = Reader

function Reader:count()
    local n = self._lib.zip_get_num_entries(self._zip, 0)
    if n < 0 then zip_error(self._lib, self._zip, "get_num_entries") end
    return tonumber(n)
end

function Reader:list()
    if self._cache then return self._cache end
    local n = self:count()
    local out = {}
    for i = 0, n - 1 do
        out[#out + 1] = stat_entry(self._lib, self._zip, i)
    end
    self._cache = out
    return out
end

-- Read by name string or 1-based index.
function Reader:read(name_or_index)
    local L = self._lib
    local f
    local size
    if type(name_or_index) == "number" then
        local idx = name_or_index - 1
        f = L.zip_fopen_index(self._zip, idx, 0)
        if f == nil then zip_error(L, self._zip, "fopen_index") end
        local entries = self:list()
        size = entries[name_or_index] and entries[name_or_index].size
    else
        -- Walk our cached list so we know the size; libzip doesn't return
        -- it from fopen so we have to stat first.
        local entries = self:list()
        local idx
        for i, e in ipairs(entries) do
            if e.name == name_or_index then idx = i - 1; size = e.size; break end
        end
        if idx == nil then
            error("zip_native: entry not found: " .. tostring(name_or_index), 2)
        end
        f = L.zip_fopen_index(self._zip, idx, 0)
        if f == nil then zip_error(L, self._zip, "fopen_index") end
    end
    if size == nil then size = 0 end
    local buf = ffi.new("unsigned char[?]", math.max(size, 1))
    local pos = 0
    while pos < size do
        local n = L.zip_fread(f, buf + pos, size - pos)
        if n < 0 then
            L.zip_fclose(f)
            error("zip_native.read: zip_fread failed", 2)
        end
        if n == 0 then break end
        pos = pos + tonumber(n)
    end
    L.zip_fclose(f)
    return ffi.string(buf, pos)
end

function Reader:extract_all(dest_dir)
    local out = {}
    for _, e in ipairs(self:list()) do
        safe_entry_name(e.name)
        local target = dest_dir .. "/" .. e.name
        if e.is_dir then
            ensure_dir(target)
        else
            ensure_dir(dirname(target))
            local body = self:read(e.name)
            local f, err = io.open(target, "wb")
            if not f then error("zip_native.extract_all: cannot create " .. target .. ": " .. tostring(err), 2) end
            f:write(body); f:close()
            out[#out + 1] = target
        end
    end
    return out
end

function Reader:close()
    if self._zip ~= nil then
        self._lib.zip_close(ffi.gc(self._zip, nil))
        self._zip = nil
    end
end

Reader.__gc = Reader.close

function M.open(path)
    local L = require_lib()
    local err = ffi.new("int[1]")
    local z = L.zip_open(path, M.ZIP_RDONLY, err)
    if z == nil then check_open(L, tonumber(err[0]), path); error("zip_native: open failed", 2) end
    return setmetatable({
        _lib  = L,
        _zip  = ffi.gc(z, L.zip_close),
        _path = path,
    }, Reader)
end

-- ===== Writer object =====================================================

local Writer = {}
Writer.__index = Writer

-- libzip needs the source buffer to remain valid until zip_close. We pin
-- every Lua-side string passed to add_file via a table on the writer so
-- the GC can't free it out from under libzip.
local function pin(self, s)
    self._pins[#self._pins + 1] = s
end

local function comp_to_enum(s)
    if s == nil or s == "deflate" then return M.ZIP_CM_DEFLATE end
    if s == "store" or s == "stored" then return M.ZIP_CM_STORE end
    error("zip_native: unknown compression '" .. tostring(s) .. "'", 3)
end

function Writer:add_file(name, bytes, opts)
    opts = opts or {}
    local L = self._lib
    pin(self, bytes)  -- keep bytes alive until close
    local src = L.zip_source_buffer(self._zip, bytes, #bytes, 0)
    if src == nil then zip_error(L, self._zip, "source_buffer") end
    local idx = L.zip_file_add(self._zip, name, src, M.ZIP_FL_ENC_UTF_8)
    if idx < 0 then
        L.zip_source_free(src)
        zip_error(L, self._zip, "file_add '" .. name .. "'")
    end
    L.zip_set_file_compression(self._zip, idx, comp_to_enum(opts.compression), opts.level or 0)
    return tonumber(idx)
end

function Writer:add_path(name, fs_path, opts)
    -- Reading the file ourselves keeps the contract identical to the
    -- pure-Lua writer (which always works with in-memory bytes) and
    -- avoids libzip's lazy-source semantics that can complicate close.
    local f, err = io.open(fs_path, "rb")
    if not f then error("zip_native.add_path: cannot open " .. tostring(fs_path) .. ": " .. tostring(err), 2) end
    local body = f:read("*a")
    f:close()
    return self:add_file(name, body, opts)
end

function Writer:close()
    if self._zip ~= nil then
        local rc = self._lib.zip_close(ffi.gc(self._zip, nil))
        self._zip = nil
        self._pins = nil  -- release pins so the GC can reclaim buffers
        if rc ~= 0 then return false end
    end
    return true
end

Writer.__gc = function(self)
    if self._zip ~= nil then
        -- Discard rather than commit on accidental GC; the caller didn't
        -- explicitly close, which probably means an error path.
        self._lib.zip_discard(self._zip)
        self._zip = nil
    end
end

function M.create(path, opts)
    opts = opts or {}
    local L = require_lib()
    local flags = M.ZIP_CREATE
    if opts.truncate then flags = flags + M.ZIP_TRUNCATE end
    if opts.exclusive then flags = flags + M.ZIP_EXCL end
    local err = ffi.new("int[1]")
    local z = L.zip_open(path, flags, err)
    if z == nil then check_open(L, tonumber(err[0]), path); error("zip_native: create failed", 2) end
    return setmetatable({
        _lib  = L,
        _zip  = z,  -- no auto-gc -- we want close() to commit
        _path = path,
        _pins = {},
    }, Writer)
end

return M
