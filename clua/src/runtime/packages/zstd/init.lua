-- zstd -- FFI wrapper over libzstd.dll.
--
-- Why this is a wrapper rather than a port:
--   zstd's decoder alone is on the order of 5-10k lines of C with a
--   fully featured FSE entropy decoder, Huffman dispatch tables, three
--   different LZ77 modes, dictionary cache handling, and a stack of
--   block-level state machines. A faithful port to pure Lua would be
--   ~3-5x larger than every other compression package in this folder
--   combined and would inflate slower than xpress on tiny inputs. For
--   the moment we delegate to the official DLL; callers without it can
--   pick xpress (Windows-native, no deps) or lz4 (pure Lua, simpler
--   format).
--
-- Public surface:
--   zstd.compress(bytes, level?)            -> bytes
--   zstd.decompress(bytes)                  -> bytes
--   zstd.compress_bound(src_size)           -> integer
--   zstd.get_frame_content_size(bytes)      -> integer | nil  (nil if unknown)
--   zstd.version_number()                   -> integer
--   zstd.is_available()                     -> bool
--
-- Compression level: 1..22; default 3 (matches libzstd's CLI default).
-- Negative levels (-1..-131072) are "fast modes"; we pass them through.

local ffi = ffi

local M = {}

ffi.cdef[[
typedef unsigned long zstd_size_t_lo;  /* 32-bit lo half is enough for the surfaces we use */
typedef unsigned int  zstd_unsigned;

typedef struct zstd_ZSTD_CCtx_s zstd_ZSTD_CCtx;
typedef struct zstd_ZSTD_DCtx_s zstd_ZSTD_DCtx;
typedef struct zstd_ZSTD_CDict_s zstd_ZSTD_CDict;
typedef struct zstd_ZSTD_DDict_s zstd_ZSTD_DDict;

/* size_t is 64-bit on Windows x64 -- use unsigned long long for the
   buffer struct fields so the layout matches what libzstd's C ABI
   expects. unsigned long is 32-bit under LLP64 and would truncate. */
typedef struct {
    const char         *src;
    unsigned long long  size;
    unsigned long long  pos;
} zstd_inBuffer;

typedef struct {
    char               *dst;
    unsigned long long  size;
    unsigned long long  pos;
} zstd_outBuffer;

unsigned   ZSTD_versionNumber(void);
/* These return size_t (8 bytes on Win x64 LLP64); 'unsigned long' would
   truncate to 32 bits, hiding the (size_t)-N error sentinels libzstd uses. */
unsigned long long ZSTD_compressBound(unsigned long srcSize);
unsigned long long ZSTD_compress(char *dst, unsigned long dstCapacity,
                                 const char *src, unsigned long srcSize, int level);
unsigned long long ZSTD_decompress(char *dst, unsigned long dstCapacity,
                                   const char *src, unsigned long srcSize);
unsigned long long ZSTD_getFrameContentSize(const char *src, unsigned long srcSize);
unsigned long long ZSTD_decompressBound(const char *src, unsigned long srcSize);
/* code is size_t too -- 64-bit so the full error sentinel reaches the predicate. */
unsigned ZSTD_isError(unsigned long long code);
const char *ZSTD_getErrorName(unsigned long long code);

/* CCtx / DCtx -- streaming + reusable state. */
zstd_ZSTD_CCtx *ZSTD_createCCtx(void);
unsigned long   ZSTD_freeCCtx(zstd_ZSTD_CCtx *cctx);
zstd_ZSTD_DCtx *ZSTD_createDCtx(void);
unsigned long   ZSTD_freeDCtx(zstd_ZSTD_DCtx *dctx);

unsigned long long ZSTD_compress2(zstd_ZSTD_CCtx *cctx,
                                  char *dst, unsigned long dstCapacity,
                                  const char *src, unsigned long srcSize);
unsigned long long ZSTD_decompressDCtx(zstd_ZSTD_DCtx *dctx,
                                       char *dst, unsigned long dstCapacity,
                                       const char *src, unsigned long srcSize);

unsigned long ZSTD_CCtx_setParameter(zstd_ZSTD_CCtx *cctx, int param, int value);
unsigned long ZSTD_CCtx_reset(zstd_ZSTD_CCtx *cctx, int reset);
unsigned long ZSTD_DCtx_reset(zstd_ZSTD_DCtx *dctx, int reset);

/* Streaming -- the advanced API: a single call drives compress / flush /
   end depending on `endOp`. Returns size_t which is 8 bytes on Win x64. */
unsigned long long ZSTD_compressStream2(zstd_ZSTD_CCtx *cctx,
                                        zstd_outBuffer *output,
                                        zstd_inBuffer *input,
                                        int endOp);
unsigned long long ZSTD_decompressStream(zstd_ZSTD_DCtx *dctx,
                                         zstd_outBuffer *output,
                                         zstd_inBuffer *input);

unsigned long long ZSTD_CStreamInSize(void);
unsigned long long ZSTD_CStreamOutSize(void);
unsigned long long ZSTD_DStreamInSize(void);
unsigned long long ZSTD_DStreamOutSize(void);

/* Dictionary support. */
zstd_ZSTD_CDict *ZSTD_createCDict(const char *dictBuffer, unsigned long dictSize,
                                  int compressionLevel);
unsigned long    ZSTD_freeCDict(zstd_ZSTD_CDict *CDict);
zstd_ZSTD_DDict *ZSTD_createDDict(const char *dictBuffer, unsigned long dictSize);
unsigned long    ZSTD_freeDDict(zstd_ZSTD_DDict *ddict);
unsigned long long ZSTD_compress_usingCDict(zstd_ZSTD_CCtx *cctx,
                                            char *dst, unsigned long dstCapacity,
                                            const char *src, unsigned long srcSize,
                                            const zstd_ZSTD_CDict *cdict);
unsigned long long ZSTD_decompress_usingDDict(zstd_ZSTD_DCtx *dctx,
                                              char *dst, unsigned long dstCapacity,
                                              const char *src, unsigned long srcSize,
                                              const zstd_ZSTD_DDict *ddict);

/* Dictionary training via the zdict API -- shipped in libzstd. The
   size_t return is 8 bytes on Win x64; mismatch would corrupt the
   stack and surface as a hang. */
unsigned long long ZDICT_trainFromBuffer(char *dictBuffer,
                                         unsigned long long dictBufferCapacity,
                                         const char *samplesBuffer,
                                         const unsigned long long *samplesSizes,
                                         unsigned int nbSamples);
unsigned int  ZDICT_isError(unsigned long long errorCode);
const char   *ZDICT_getErrorName(unsigned long long errorCode);
]]

-- Parameter codes / reset directives -- matching libzstd's public enums.
local ZSTD_c_compressionLevel = 100
local ZSTD_e_continue         = 0
local ZSTD_e_flush            = 1
local ZSTD_e_end              = 2
local ZSTD_reset_session_only = 1

-- Sentinel values returned by ZSTD_getFrameContentSize. Built via ffi.new
-- so the integer literals fit a uint64 without going through a Lua double.
local ZSTD_CONTENTSIZE_UNKNOWN = ffi.new("unsigned long long", -2)  -- ~0ULL - 1
local ZSTD_CONTENTSIZE_ERROR   = ffi.new("unsigned long long", -1)  -- ~0ULL

local _lib_state -- nil = unprobed, false = absent, table = loaded

local function probe()
    if _lib_state ~= nil then return _lib_state end
    local override = os.getenv("CLUA_ZSTD_DLL")
    -- Try the names libzstd ships under on Windows. The official builds
    -- are libzstd.dll; some package managers rename to zstd.dll.
    local names = { "libzstd", "zstd", "libzstd.dll", "zstd.dll" }
    if override and override ~= "" then
        table.insert(names, 1, override)
    end
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then
            _lib_state = { lib = lib, name = n }
            return _lib_state
        end
    end
    _lib_state = false
    return false
end

local function require_lib()
    local st = probe()
    if st == false then
        error("zstd: libzstd.dll not found on the search path. "
            .. "Drop libzstd.dll next to the CLua binary, or use "
            .. "xpress (Windows-native, no deps) or lz4 (pure Lua) instead.")
    end
    return st.lib
end

local function check(rc, what)
    -- libzstd encodes errors as size_t values near (size_t)-1. A magnitude
    -- comparison is fragile: it depends on the return staying 64-bit (a
    -- truncated 'unsigned long' rc loses the high bits and slips past), so
    -- gate through the canonical ZSTD_isError predicate instead.
    local lib = _lib_state.lib
    if lib.ZSTD_isError(rc) ~= 0 then
        local name = ffi.string(lib.ZSTD_getErrorName(rc))
        error(string.format("zstd.%s: %s", what, name))
    end
end

function M.is_available()
    return probe() ~= false
end

function M.version_number()
    return tonumber(require_lib().ZSTD_versionNumber())
end

function M.compress_bound(src_size)
    return tonumber(require_lib().ZSTD_compressBound(src_size))
end

function M.compress(bytes, level)
    if type(bytes) ~= "string" then
        error("zstd.compress: expected string, got " .. type(bytes))
    end
    local lib = require_lib()
    level = level or 3
    local src_size = #bytes
    local cap      = tonumber(lib.ZSTD_compressBound(src_size))
    local dst      = ffi.new("char[?]", cap)
    local rc       = lib.ZSTD_compress(dst, cap, bytes, src_size, level)
    check(rc, "compress")
    return ffi.string(dst, tonumber(rc))
end

function M.get_frame_content_size(bytes)
    local lib = require_lib()
    local v   = lib.ZSTD_getFrameContentSize(bytes, #bytes)
    if v == ZSTD_CONTENTSIZE_UNKNOWN then return nil end
    if v == ZSTD_CONTENTSIZE_ERROR then
        error("zstd: bad frame (cannot read content size)")
    end
    return tonumber(v)
end

function M.decompress(bytes)
    if type(bytes) ~= "string" then
        error("zstd.decompress: expected string, got " .. type(bytes))
    end
    local lib = require_lib()
    -- Try to pull the original size out of the frame header.
    local fcs = lib.ZSTD_getFrameContentSize(bytes, #bytes)
    local cap
    if fcs == ZSTD_CONTENTSIZE_UNKNOWN or fcs == ZSTD_CONTENTSIZE_ERROR then
        -- Fall back to ZSTD_decompressBound which gives an upper bound
        -- for any reachable output across the whole frame.
        local bound = lib.ZSTD_decompressBound(bytes, #bytes)
        if bound == ZSTD_CONTENTSIZE_ERROR then
            error("zstd.decompress: cannot determine output size from frame")
        end
        cap = tonumber(bound)
    else
        cap = tonumber(fcs)
        if cap == 0 then return "" end
    end
    -- Guard against absurd sizes (libzstd will faithfully report whatever
    -- a malicious header claims). 1 GiB cap by default; callers needing
    -- bigger should drive a streaming context directly.
    if cap > 1024 * 1024 * 1024 then
        error(string.format("zstd.decompress: frame claims %d bytes (>1GiB) -- refusing", cap))
    end
    local dst = ffi.new("char[?]", cap > 0 and cap or 1)
    local rc  = lib.ZSTD_decompress(dst, cap, bytes, #bytes)
    check(rc, "decompress")
    return ffi.string(dst, tonumber(rc))
end

-- ===== Streaming compressor / decompressor ===============================
-- compressor(opts) -- opts = { level = 3 }
--   :update(chunk) -> bytes (zero or more emitted)
--   :final()       -> bytes (flushes the frame trailer)
-- decompressor()
--   :update(chunk) -> bytes
--   :final()       -> bytes (asserts the stream has finished)

local _compressor_mt = {}
_compressor_mt.__index = _compressor_mt

local function _check_zstd(lib, rc, what)
    if lib.ZSTD_isError(rc) ~= 0 then
        local name = ffi.string(lib.ZSTD_getErrorName(rc))
        error(string.format("zstd.%s: %s", what, name))
    end
end

local function _drive_stream(self, chunk, end_op)
    local lib  = self._lib
    local cctx = self._cctx
    local in_buf  = ffi.new("zstd_inBuffer")
    local out_sz  = tonumber(lib.ZSTD_CStreamOutSize())
    local out_buf = ffi.new("zstd_outBuffer")
    local dst_mem = ffi.new("char[?]", out_sz)
    local src_mem
    if chunk and #chunk > 0 then
        src_mem = ffi.new("char[?]", #chunk)
        ffi.copy(src_mem, chunk, #chunk)
        in_buf.src  = src_mem
        in_buf.size = #chunk
    else
        in_buf.size = 0
    end
    in_buf.pos = 0
    local pieces, np = {}, 0
    while true do
        out_buf.dst  = dst_mem
        out_buf.size = out_sz
        out_buf.pos  = 0
        local remaining = lib.ZSTD_compressStream2(cctx, out_buf, in_buf, end_op)
        _check_zstd(lib, remaining, "compressor")
        local got     = tonumber(out_buf.pos) or 0
        local in_pos  = tonumber(in_buf.pos)  or 0
        local in_size = tonumber(in_buf.size) or 0
        if got > 0 then
            np = np + 1; pieces[np] = ffi.string(dst_mem, got)
        end
        if end_op == ZSTD_e_continue then
            if in_pos == in_size then break end
        else
            if tonumber(remaining) == 0 then break end
        end
    end
    return table.concat(pieces)
end

function _compressor_mt:update(chunk)
    if self._done then error("zstd.compressor: already finalised") end
    if chunk == nil or chunk == "" then return "" end
    return _drive_stream(self, chunk, ZSTD_e_continue)
end

function _compressor_mt:final()
    if self._done then error("zstd.compressor: already finalised") end
    self._done = true
    local tail = _drive_stream(self, nil, ZSTD_e_end)
    self._lib.ZSTD_freeCCtx(self._cctx)
    return tail
end

function M.compressor(opts)
    opts = opts or {}
    local lib  = require_lib()
    local cctx = lib.ZSTD_createCCtx()
    if cctx == nil then error("zstd.compressor: ZSTD_createCCtx failed") end
    local rc = lib.ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, opts.level or 3)
    if lib.ZSTD_isError(rc) ~= 0 then
        lib.ZSTD_freeCCtx(cctx)
        _check_zstd(lib, rc, "compressor (level)")
    end
    return setmetatable({
        _lib  = lib,
        _cctx = cctx,
        _done = false,
    }, _compressor_mt)
end

local _decompressor_mt = {}
_decompressor_mt.__index = _decompressor_mt

function _decompressor_mt:update(chunk)
    if self._done then error("zstd.decompressor: already finalised") end
    if chunk == nil or chunk == "" then return "" end
    local lib  = self._lib
    local dctx = self._dctx
    local out_sz  = tonumber(lib.ZSTD_DStreamOutSize())
    local out_buf = ffi.new("zstd_outBuffer")
    local in_buf  = ffi.new("zstd_inBuffer")
    local dst_mem = ffi.new("char[?]", out_sz)
    local src_mem = ffi.new("char[?]", #chunk)
    ffi.copy(src_mem, chunk, #chunk)
    in_buf.src  = src_mem
    in_buf.size = #chunk
    in_buf.pos  = 0
    local pieces, np = {}, 0
    while true do
        local in_pos  = tonumber(in_buf.pos)  or 0
        local in_size = tonumber(in_buf.size) or 0
        if in_pos >= in_size then break end
        out_buf.dst  = dst_mem
        out_buf.size = out_sz
        out_buf.pos  = 0
        local rc = lib.ZSTD_decompressStream(dctx, out_buf, in_buf)
        _check_zstd(lib, rc, "decompressor")
        local got = tonumber(out_buf.pos) or 0
        if got > 0 then
            np = np + 1; pieces[np] = ffi.string(dst_mem, got)
        end
        if got == 0 and tonumber(in_buf.pos) == in_pos then break end
    end
    return table.concat(pieces)
end

function _decompressor_mt:final()
    if self._done then error("zstd.decompressor: already finalised") end
    self._done = true
    self._lib.ZSTD_freeDCtx(self._dctx)
    return ""
end

function M.decompressor()
    local lib = require_lib()
    local dctx = lib.ZSTD_createDCtx()
    if dctx == nil then error("zstd.decompressor: ZSTD_createDCtx failed") end
    return setmetatable({
        _lib  = lib,
        _dctx = dctx,
        _done = false,
    }, _decompressor_mt)
end

-- ===== Dictionary training + use =========================================
-- train_dict(samples, dict_size_max) takes an array of byte strings and
-- returns a dictionary blob (binary string) suitable for compress_with_dict.

function M.train_dict(samples, dict_size_max)
    if type(samples) ~= "table" then
        error("zstd.train_dict: samples must be an array of strings")
    end
    local lib = require_lib()
    -- Concatenate samples into one buffer and pass per-sample sizes.
    local total = 0
    for _, s in ipairs(samples) do
        if type(s) ~= "string" then
            error("zstd.train_dict: each sample must be a string")
        end
        total = total + #s
    end
    if total == 0 then
        error("zstd.train_dict: no sample data provided")
    end
    local cat = ffi.new("char[?]", total)
    local cat_p = ffi.cast("char *", cat)
    -- samplesSizes is size_t[] in libzstd, which is uint64 on Win x64.
    local sizes = ffi.new("unsigned long long[?]", #samples)
    local pos = 0
    for i, s in ipairs(samples) do
        ffi.copy(cat_p + pos, s, #s)
        sizes[i - 1] = #s
        pos = pos + #s
    end
    local cap = dict_size_max or 64 * 1024
    local dict = ffi.new("char[?]", cap)
    local rc = lib.ZDICT_trainFromBuffer(dict, cap, cat, sizes, #samples)
    if lib.ZDICT_isError(rc) ~= 0 then
        local name = ffi.string(lib.ZDICT_getErrorName(rc))
        error("zstd.train_dict: " .. name)
    end
    return ffi.string(dict, tonumber(rc))
end

function M.compress_with_dict(bytes, dict, level)
    if type(bytes) ~= "string" then
        error("zstd.compress_with_dict: bytes must be a string")
    end
    if type(dict) ~= "string" then
        error("zstd.compress_with_dict: dict must be a string blob")
    end
    local lib  = require_lib()
    local cctx = lib.ZSTD_createCCtx()
    if cctx == nil then error("zstd.compress_with_dict: ZSTD_createCCtx failed") end
    local cdict = lib.ZSTD_createCDict(dict, #dict, level or 3)
    if cdict == nil then
        lib.ZSTD_freeCCtx(cctx)
        error("zstd.compress_with_dict: ZSTD_createCDict failed")
    end
    local cap = tonumber(lib.ZSTD_compressBound(#bytes))
    local dst = ffi.new("char[?]", cap)
    local rc = lib.ZSTD_compress_usingCDict(cctx, dst, cap, bytes, #bytes, cdict)
    local ok = (lib.ZSTD_isError(rc) == 0)
    local err_name
    if not ok then err_name = ffi.string(lib.ZSTD_getErrorName(rc)) end
    lib.ZSTD_freeCDict(cdict)
    lib.ZSTD_freeCCtx(cctx)
    if not ok then
        error("zstd.compress_with_dict: " .. err_name)
    end
    return ffi.string(dst, tonumber(rc))
end

function M.decompress_with_dict(bytes, dict)
    if type(bytes) ~= "string" or type(dict) ~= "string" then
        error("zstd.decompress_with_dict: bytes + dict must be strings")
    end
    local lib  = require_lib()
    local dctx = lib.ZSTD_createDCtx()
    if dctx == nil then error("zstd.decompress_with_dict: ZSTD_createDCtx failed") end
    local ddict = lib.ZSTD_createDDict(dict, #dict)
    if ddict == nil then
        lib.ZSTD_freeDCtx(dctx)
        error("zstd.decompress_with_dict: ZSTD_createDDict failed")
    end
    local fcs = lib.ZSTD_getFrameContentSize(bytes, #bytes)
    local cap
    if fcs == ZSTD_CONTENTSIZE_UNKNOWN or fcs == ZSTD_CONTENTSIZE_ERROR then
        cap = #bytes * 16 + 1024
    else
        cap = tonumber(fcs)
    end
    local dst = ffi.new("char[?]", cap > 0 and cap or 1)
    local rc = lib.ZSTD_decompress_usingDDict(dctx, dst, cap, bytes, #bytes, ddict)
    local ok = (lib.ZSTD_isError(rc) == 0)
    local err_name
    if not ok then err_name = ffi.string(lib.ZSTD_getErrorName(rc)) end
    lib.ZSTD_freeDDict(ddict)
    lib.ZSTD_freeDCtx(dctx)
    if not ok then
        error("zstd.decompress_with_dict: " .. err_name)
    end
    return ffi.string(dst, tonumber(rc))
end

return M
