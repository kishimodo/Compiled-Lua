-- brotli -- Brotli (RFC 7932) compression bindings.
--
-- Public surface:
--   brotli.available()                -- true if brotli enc + dec loaded
--   brotli.version()                  -- encoder version number as int
--
-- One-shot:
--   brotli.compress(bytes, opts?)     -> bytes
--     opts: { quality = 0..11 (default 11),
--             mode    = "generic"|"text"|"font" (default "generic"),
--             lgwin   = 10..24 (default 22) }
--   brotli.decompress(bytes)          -> bytes
--
-- Streaming:
--   brotli.compressor(opts?)          -> enc
--     enc:write(bytes)                -- buffer; returns any output bytes ready
--     enc:finish()                    -- flush remaining + final block
--     enc:reset()
--   brotli.decompressor()             -> dec
--     dec:write(bytes)                -- feed compressed input; returns decoded bytes
--     dec:finish()                    -- assert stream is at end
--
-- DLL load order (first hit wins):
--   1. $CLUA_BROTLI_DLL
--   2. "brotli" / "brotli.dll"
--   3. Split-build encoder + decoder: "brotlienc"/"brotlidec" or
--      "libbrotlienc"/"libbrotlidec"

local M = {}

ffi.cdef[[
typedef int    BROTLI_BOOL;
typedef struct BrotliEncoderStateStruct BrotliEncoderState;
typedef struct BrotliDecoderStateStruct BrotliDecoderState;

typedef enum {
    BROTLI_OPERATION_PROCESS       = 0,
    BROTLI_OPERATION_FLUSH         = 1,
    BROTLI_OPERATION_FINISH        = 2,
    BROTLI_OPERATION_EMIT_METADATA = 3
} BrotliEncoderOperation;

typedef enum {
    BROTLI_PARAM_MODE                       = 0,
    BROTLI_PARAM_QUALITY                    = 1,
    BROTLI_PARAM_LGWIN                      = 2,
    BROTLI_PARAM_LGBLOCK                    = 3,
    BROTLI_PARAM_DISABLE_LITERAL_CONTEXT_MODELING = 4,
    BROTLI_PARAM_SIZE_HINT                  = 5,
    BROTLI_PARAM_LARGE_WINDOW               = 6,
    BROTLI_PARAM_NPOSTFIX                   = 7,
    BROTLI_PARAM_NDIRECT                    = 8,
    BROTLI_PARAM_STREAM_OFFSET              = 9
} BrotliEncoderParameter;

typedef enum {
    BROTLI_DECODER_RESULT_ERROR             = 0,
    BROTLI_DECODER_RESULT_SUCCESS           = 1,
    BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT  = 2,
    BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT = 3
} BrotliDecoderResult;

/* Encoder API */
BrotliEncoderState *BrotliEncoderCreateInstance(void *alloc, void *free, void *opaque);
void                BrotliEncoderDestroyInstance(BrotliEncoderState *state);
int                 BrotliEncoderSetParameter(BrotliEncoderState *state,
                                              BrotliEncoderParameter param, unsigned int value);
int                 BrotliEncoderCompressStream(BrotliEncoderState *state,
                                                BrotliEncoderOperation op,
                                                size_t *available_in, const unsigned char **next_in,
                                                size_t *available_out, unsigned char **next_out,
                                                size_t *total_out);
int                 BrotliEncoderIsFinished(BrotliEncoderState *state);
int                 BrotliEncoderHasMoreOutput(BrotliEncoderState *state);
const unsigned char *BrotliEncoderTakeOutput(BrotliEncoderState *state, size_t *size);
unsigned int        BrotliEncoderVersion(void);
size_t              BrotliEncoderMaxCompressedSize(size_t input_size);

int BrotliEncoderCompress(int quality, int lgwin, int mode,
                          size_t input_size, const unsigned char *input_buffer,
                          size_t *encoded_size, unsigned char *encoded_buffer);

/* Decoder API */
BrotliDecoderState *BrotliDecoderCreateInstance(void *alloc, void *free, void *opaque);
void                BrotliDecoderDestroyInstance(BrotliDecoderState *state);
int                 BrotliDecoderDecompressStream(BrotliDecoderState *state,
                                                  size_t *available_in, const unsigned char **next_in,
                                                  size_t *available_out, unsigned char **next_out,
                                                  size_t *total_out);
int                 BrotliDecoderDecompress(size_t encoded_size, const unsigned char *encoded_buffer,
                                            size_t *decoded_size, unsigned char *decoded_buffer);
int                 BrotliDecoderIsFinished(BrotliDecoderState *state);
const unsigned char *BrotliDecoderTakeOutput(BrotliDecoderState *state, size_t *size);
unsigned int        BrotliDecoderVersion(void);
]]

-- ===== Mode constants ====================================================

M.MODE_GENERIC = 0
M.MODE_TEXT    = 1
M.MODE_FONT    = 2

M.MIN_QUALITY  = 0
M.MAX_QUALITY  = 11

M.MIN_WINDOW_BITS = 10
M.MAX_WINDOW_BITS = 24

-- ===== Lazy DLL loader ===================================================

-- We allow either a single unified DLL exporting both encoder + decoder
-- symbols (the official Brotli build does this when compiled as a
-- shared lib with all features enabled) OR a split pair of DLLs --
-- brotlienc.dll / brotlidec.dll. The runtime picks whichever it finds.

local _lib_enc, _lib_dec, _load_err

local function try_unified(name)
    local ok, lib = pcall(ffi.load, name)
    if not ok then return nil end
    -- Probe one encoder + one decoder symbol via ffi to confirm
    -- the unified build has both halves.
    local has_enc = pcall(function() local _ = lib.BrotliEncoderVersion end)
    local has_dec = pcall(function() local _ = lib.BrotliDecoderVersion end)
    if has_enc and has_dec then return lib end
    return nil
end

local function load_libs()
    if _lib_enc and _lib_dec then return _lib_enc, _lib_dec end
    if _load_err then return nil end
    -- Try unified first.
    local unified_names = {}
    local env_dll = os.getenv("CLUA_BROTLI_DLL")
    if env_dll and #env_dll > 0 then unified_names[#unified_names + 1] = env_dll end
    unified_names[#unified_names + 1] = "brotli"
    unified_names[#unified_names + 1] = "brotli.dll"
    unified_names[#unified_names + 1] = "libbrotli"
    for _, n in ipairs(unified_names) do
        local lib = try_unified(n)
        if lib then _lib_enc = lib; _lib_dec = lib; return lib, lib end
    end
    -- Split-build.
    local enc_names = { "brotlienc", "brotlienc.dll", "libbrotlienc", "libbrotlienc.dll" }
    local dec_names = { "brotlidec", "brotlidec.dll", "libbrotlidec", "libbrotlidec.dll" }
    local enc, dec
    for _, n in ipairs(enc_names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then enc = lib; break end
    end
    for _, n in ipairs(dec_names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then dec = lib; break end
    end
    if enc and dec then _lib_enc = enc; _lib_dec = dec; return enc, dec end
    _load_err = "brotli: brotli.dll (or brotlienc.dll + brotlidec.dll) not found. "
        .. "Set CLUA_BROTLI_DLL or drop the DLLs next to CLua."
    return nil
end

function M.available()
    local a, b = load_libs()
    return a ~= nil and b ~= nil
end

local function require_libs()
    local a, b = load_libs()
    if a == nil then error(_load_err, 3) end
    return a, b
end

function M.version()
    local enc = load_libs()
    if enc == nil then return 0 end
    return tonumber(enc.BrotliEncoderVersion())
end

-- ===== Option parsing ====================================================

local function mode_to_enum(s)
    if s == nil or s == "generic" then return M.MODE_GENERIC end
    if s == "text" then return M.MODE_TEXT end
    if s == "font" then return M.MODE_FONT end
    error("brotli: unknown mode '" .. tostring(s) .. "'", 3)
end

local function parse_opts(opts)
    opts = opts or {}
    local quality = opts.quality or 11
    local mode    = mode_to_enum(opts.mode)
    local lgwin   = opts.lgwin   or 22
    local lgblock = opts.lgblock
    if quality < 0 or quality > 11 then
        error("brotli: quality must be 0..11", 3)
    end
    if lgwin < 10 or lgwin > 24 then
        error("brotli: lgwin must be 10..24", 3)
    end
    return quality, mode, lgwin, lgblock
end

-- ===== One-shot compress / decompress ====================================

function M.compress(bytes, opts)
    if type(bytes) ~= "string" then
        error("brotli.compress: bytes must be a string", 2)
    end
    local enc = require_libs()
    local quality, mode, lgwin = parse_opts(opts)
    local in_len = #bytes
    local max_out = tonumber(enc.BrotliEncoderMaxCompressedSize(in_len))
    if max_out == 0 then max_out = in_len + 64 end  -- safety floor
    local out_buf = ffi.new("unsigned char[?]", max_out)
    local out_size = ffi.new("size_t[1]", max_out)
    local rc = enc.BrotliEncoderCompress(
        quality, lgwin, mode,
        in_len, ffi.cast("const unsigned char *", bytes),
        out_size, out_buf)
    if rc == 0 then error("brotli.compress: encoder rejected input", 2) end
    return ffi.string(out_buf, tonumber(out_size[0]))
end

function M.decompress(bytes)
    if type(bytes) ~= "string" then
        error("brotli.decompress: bytes must be a string", 2)
    end
    local _, dec = require_libs()
    -- Try the one-shot first with a guess at output size (4x input is a
    -- common ratio); on insufficient buffer, fall back to streaming.
    local guess = math.max(#bytes * 4, 1024)
    local last_err
    for _ = 1, 6 do
        local out_buf = ffi.new("unsigned char[?]", guess)
        local out_size = ffi.new("size_t[1]", guess)
        local rc = dec.BrotliDecoderDecompress(
            #bytes, ffi.cast("const unsigned char *", bytes),
            out_size, out_buf)
        if rc == 1 then  -- SUCCESS
            return ffi.string(out_buf, tonumber(out_size[0]))
        end
        if rc == 3 then  -- NEEDS_MORE_OUTPUT -- double the buffer and retry
            guess = guess * 4
            last_err = "needs more output"
        else
            last_err = "decoder error " .. tostring(rc)
            break
        end
    end
    -- Streaming fallback for very large or oversized outputs.
    local state = dec.BrotliDecoderCreateInstance(nil, nil, nil)
    if state == nil then error("brotli.decompress: no memory", 2) end
    state = ffi.gc(state, dec.BrotliDecoderDestroyInstance)
    local in_left = ffi.new("size_t[1]", #bytes)
    local in_p    = ffi.new("const unsigned char *[1]", ffi.cast("const unsigned char *", bytes))
    local pieces  = {}
    local chunk   = 1 << 16
    local buf     = ffi.new("unsigned char[?]", chunk)
    while true do
        local out_left = ffi.new("size_t[1]", chunk)
        local out_p    = ffi.new("unsigned char *[1]", buf)
        local rc = dec.BrotliDecoderDecompressStream(state, in_left, in_p, out_left, out_p, nil)
        local produced = chunk - tonumber(out_left[0])
        if produced > 0 then pieces[#pieces + 1] = ffi.string(buf, produced) end
        if rc == 1 then return table.concat(pieces) end
        if rc == 2 then
            error("brotli.decompress: needs more input (truncated stream)", 2)
        end
        if rc == 0 then
            error("brotli.decompress: " .. (last_err or "decoder error"), 2)
        end
        -- rc == 3: needs more output -- loop continues with a fresh buf.
    end
end

-- ===== Streaming compressor ==============================================

local Encoder = {}
Encoder.__index = Encoder

function M.compressor(opts)
    local enc_lib = require_libs()
    local quality, mode, lgwin, lgblock = parse_opts(opts)
    local s = enc_lib.BrotliEncoderCreateInstance(nil, nil, nil)
    if s == nil then error("brotli.compressor: no memory", 2) end
    enc_lib.BrotliEncoderSetParameter(s, 1, quality)  -- BROTLI_PARAM_QUALITY
    enc_lib.BrotliEncoderSetParameter(s, 0, mode)     -- BROTLI_PARAM_MODE
    enc_lib.BrotliEncoderSetParameter(s, 2, lgwin)    -- BROTLI_PARAM_LGWIN
    if lgblock then
        enc_lib.BrotliEncoderSetParameter(s, 3, lgblock)
    end
    return setmetatable({
        _lib   = enc_lib,
        _state = ffi.gc(s, enc_lib.BrotliEncoderDestroyInstance),
        _done  = false,
    }, Encoder)
end

-- Internal: drive CompressStream with the given operation and collect
-- whatever output the encoder produces.
local function enc_drive(self, op, input_bytes)
    local enc = self._lib
    local pieces = {}
    local in_len = input_bytes and #input_bytes or 0
    local in_p   = ffi.new("const unsigned char *[1]",
        input_bytes and ffi.cast("const unsigned char *", input_bytes) or nil)
    local in_left = ffi.new("size_t[1]", in_len)
    -- Loop until encoder has no more input pending AND no buffered output.
    while true do
        local out_left = ffi.new("size_t[1]", 0)
        local out_p    = ffi.new("unsigned char *[1]", nil)
        local rc = enc.BrotliEncoderCompressStream(self._state, op,
            in_left, in_p, out_left, out_p, nil)
        if rc == 0 then error("brotli.encoder: stream error", 3) end
        -- Drain any buffered output regardless of op.
        while enc.BrotliEncoderHasMoreOutput(self._state) ~= 0 do
            local sz = ffi.new("size_t[1]", 0)
            local out = enc.BrotliEncoderTakeOutput(self._state, sz)
            local n = tonumber(sz[0])
            if n > 0 and out ~= nil then
                pieces[#pieces + 1] = ffi.string(out, n)
            else
                break
            end
        end
        if tonumber(in_left[0]) == 0 then
            if op == 2 then  -- FINISH
                if enc.BrotliEncoderIsFinished(self._state) ~= 0 then break end
            else
                break
            end
        end
    end
    return table.concat(pieces)
end

function Encoder:write(bytes)
    if self._done then error("brotli.encoder: stream already finished", 2) end
    if type(bytes) ~= "string" then
        error("brotli.encoder:write expects a string", 2)
    end
    return enc_drive(self, 0, bytes)
end

function Encoder:flush()
    if self._done then return "" end
    return enc_drive(self, 1, nil)
end

function Encoder:finish()
    if self._done then return "" end
    local out = enc_drive(self, 2, nil)
    self._done = true
    return out
end

function Encoder:destroy()
    if self._state ~= nil then
        self._lib.BrotliEncoderDestroyInstance(ffi.gc(self._state, nil))
        self._state = nil
    end
end

Encoder.__gc = Encoder.destroy

-- ===== Streaming decompressor ============================================

local Decoder = {}
Decoder.__index = Decoder

function M.decompressor()
    local _, dec = require_libs()
    local s = dec.BrotliDecoderCreateInstance(nil, nil, nil)
    if s == nil then error("brotli.decompressor: no memory", 2) end
    return setmetatable({
        _lib   = dec,
        _state = ffi.gc(s, dec.BrotliDecoderDestroyInstance),
        _done  = false,
    }, Decoder)
end

function Decoder:write(bytes)
    if self._done then error("brotli.decoder: stream already finished", 2) end
    if type(bytes) ~= "string" then
        error("brotli.decoder:write expects a string", 2)
    end
    local dec = self._lib
    local in_left = ffi.new("size_t[1]", #bytes)
    local in_p    = ffi.new("const unsigned char *[1]", ffi.cast("const unsigned char *", bytes))
    local pieces  = {}
    local chunk   = 1 << 16
    local buf     = ffi.new("unsigned char[?]", chunk)
    while true do
        local out_left = ffi.new("size_t[1]", chunk)
        local out_p    = ffi.new("unsigned char *[1]", buf)
        local rc = dec.BrotliDecoderDecompressStream(self._state, in_left, in_p, out_left, out_p, nil)
        local produced = chunk - tonumber(out_left[0])
        if produced > 0 then pieces[#pieces + 1] = ffi.string(buf, produced) end
        if rc == 1 then self._done = true; break end
        if rc == 2 then break end  -- needs more input
        if rc == 0 then error("brotli.decoder: stream error", 2) end
        -- rc == 3: needs more output -- loop with a fresh out buf.
    end
    return table.concat(pieces)
end

function Decoder:finish()
    if self._lib.BrotliDecoderIsFinished(self._state) == 0 then
        error("brotli.decoder:finish called before end of stream", 2)
    end
    self._done = true
    return ""
end

function Decoder:destroy()
    if self._state ~= nil then
        self._lib.BrotliDecoderDestroyInstance(ffi.gc(self._state, nil))
        self._state = nil
    end
end

Decoder.__gc = Decoder.destroy

return M
