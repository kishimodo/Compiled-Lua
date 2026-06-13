-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- xpress -- thin wrapper around ntdll's RtlCompressBuffer family.
--
-- Why this package exists:
--   Windows ships three useful built-in compression formats in ntdll
--   (LZNT1, XPRESS, XPRESS_HUFF). The kernel uses them for hibernation,
--   memory compression, prefetch, WIM, and -- relevant here -- the
--   CLua package loader uses XPRESS_HUFF (format 4) to shrink embedded
--   bytecode blobs. Exposing the same primitives to Lua means scripts
--   can produce / consume the exact byte layout the C side already
--   understands.
--
-- Public surface:
--   xpress.LZNT1, xpress.XPRESS, xpress.XPRESS_HUFF   -- format constants
--   xpress.compress(bytes, format?)                   -> bytes
--   xpress.decompress(bytes, format?, original_size)  -> bytes
--   xpress.compress_chunked(reader, writer, format?)  -- pull/push streaming
--   xpress.frame_compress(bytes, format?)             -> bytes (magic + len header)
--   xpress.frame_decompress(bytes)                    -> bytes  (header drives sizing)
--
-- format defaults to XPRESS_HUFF for both compress and decompress.
-- raw compress/decompress doesn't store the uncompressed length -- the
-- caller is expected to track it. frame_* variants prefix the output
-- with a 12-byte header (magic 'LVX1' + format u32 + original_len u32)
-- so the decompressor can recover the size and format itself.

local ffi = ffi

local M = {}

-- Format constants -- match WDK's COMPRESSION_FORMAT_* values.
M.LZNT1       = 2
M.XPRESS      = 3
M.XPRESS_HUFF = 4

-- Tabular form for callers preferring `xpress.formats.XPRESS_HUFF`.
M.formats = {
    LZNT1       = 2,
    XPRESS      = 3,
    XPRESS_HUFF = 4,
}

-- Frame format magic. 4 ASCII bytes 'LVX1' little-endian = 0x3158564C.
-- Distinct from the C package loader's 'LVC1' = 0x3143564C so callers
-- can't accidentally feed one to the other.
local FRAME_MAGIC      = 0x3158564C
local FRAME_HDR_SIZE   = 12  -- magic(4) + format(4) + original_len(4)

-- ===== FFI cdefs =========================================================
-- CLua's ffi.cdef doesn't support typedef'd function-pointer types, so
-- we declare the ntdll routines as straight C prototypes. ffi.load's
-- auto-preload of ntdll publishes them under ffi.C for direct use.

ffi.cdef[[
long RtlGetCompressionWorkSpaceSize(
    unsigned short  CompressionFormatAndEngine,
    unsigned long  *CompressBufferWorkSpaceSize,
    unsigned long  *CompressFragmentWorkSpaceSize);

long RtlCompressBuffer(
    unsigned short  CompressionFormatAndEngine,
    unsigned char  *UncompressedBuffer,
    unsigned long   UncompressedBufferSize,
    unsigned char  *CompressedBuffer,
    unsigned long   CompressedBufferSize,
    unsigned long   UncompressedChunkSize,
    unsigned long  *FinalCompressedSize,
    void           *WorkSpace);

long RtlDecompressBufferEx(
    unsigned short  CompressionFormat,
    unsigned char  *UncompressedBuffer,
    unsigned long   UncompressedBufferSize,
    unsigned char  *CompressedBuffer,
    unsigned long   CompressedBufferSize,
    unsigned long  *FinalUncompressedSize,
    void           *WorkSpace);

long RtlDecompressBuffer(
    unsigned short  CompressionFormat,
    unsigned char  *UncompressedBuffer,
    unsigned long   UncompressedBufferSize,
    unsigned char  *CompressedBuffer,
    unsigned long   CompressedBufferSize,
    unsigned long  *FinalUncompressedSize);
]]

local C = ffi.C

-- COMPRESSION_ENGINE_STANDARD = 1, MAXIMUM = 0x100. XPRESS_HUFF only
-- accepts STANDARD; LZNT1 + XPRESS accept either. Engine choice is
-- ORed with the format value when passed to RtlCompressBuffer.
local ENGINE_STANDARD = 1

local function packed_format(fmt, engine)
    return bit.bor(fmt, engine or ENGINE_STANDARD)
end

local function get_workspace(fmt)
    local main = ffi.new("unsigned long[1]")
    local frag = ffi.new("unsigned long[1]")
    local st = C.RtlGetCompressionWorkSpaceSize(packed_format(fmt), main, frag)
    if st ~= 0 then
        error(string.format("xpress: RtlGetCompressionWorkSpaceSize failed status=0x%X", st))
    end
    return main[0], frag[0]
end

-- ===== compress ==========================================================

function M.compress(bytes, format)
    if type(bytes) ~= "string" then
        error("xpress.compress: expected string, got " .. type(bytes))
    end
    format = format or M.XPRESS_HUFF
    -- Empty input: RtlCompressBuffer faults on a zero-length buffer, so encode
    -- it as the empty string (decompress mirrors this for original_size 0).
    if #bytes == 0 then return "" end
    local main_ws = get_workspace(format)
    -- Output slack must cover the format's FIXED per-block overhead, which
    -- dominates on tiny inputs: XPRESS_HUFF always emits a 256-byte Huffman
    -- table, and every format adds a chunk/block header, so a 1-byte input can
    -- exceed its own size many times over. +512 covers the Huffman table plus
    -- headers; /8 gives per-chunk slack for incompressible data. The old
    -- in_len/16 + 64 was too small and returned STATUS_BUFFER_TOO_SMALL.
    local in_len  = #bytes
    local out_cap = in_len + math.floor(in_len / 8) + 512
    local in_buf  = ffi.new("unsigned char[?]", in_len > 0 and in_len or 1)
    if in_len > 0 then ffi.copy(in_buf, bytes, in_len) end
    local out_buf = ffi.new("unsigned char[?]", out_cap)
    local ws      = ffi.new("unsigned char[?]", main_ws > 0 and main_ws or 1)
    local written = ffi.new("unsigned long[1]")
    -- Chunk size = 4096 -- ntdll's default; bigger chunks aren't
    -- always supported and don't reliably help ratio.
    local st = C.RtlCompressBuffer(packed_format(format),
                                   in_buf,  in_len,
                                   out_buf, out_cap,
                                   4096, written, ws)
    if st ~= 0 then
        error(string.format("xpress.compress: RtlCompressBuffer failed status=0x%X", st))
    end
    return ffi.string(out_buf, written[0])
end

-- ===== decompress ========================================================

function M.decompress(bytes, format, original_size)
    if type(bytes) ~= "string" then
        error("xpress.decompress: expected string, got " .. type(bytes))
    end
    if type(original_size) ~= "number" or original_size < 0 then
        error("xpress.decompress: original_size required (caller-tracked)")
    end
    -- Mirror compress's empty-input encoding (and avoid a zero-length-buffer
    -- fault in RtlDecompressBuffer).
    if original_size == 0 or #bytes == 0 then return "" end
    format = format or M.XPRESS_HUFF
    local in_len  = #bytes
    local in_buf  = ffi.new("unsigned char[?]", in_len > 0 and in_len or 1)
    if in_len > 0 then ffi.copy(in_buf, bytes, in_len) end
    local out_buf = ffi.new("unsigned char[?]", original_size > 0 and original_size or 1)
    local written = ffi.new("unsigned long[1]")
    -- Prefer the Ex variant: it works for every format including
    -- XPRESS_HUFF. The legacy RtlDecompressBuffer doesn't support it.
    local _, frag_ws = get_workspace(format)
    local scratch = frag_ws > 0 and ffi.new("unsigned char[?]", frag_ws) or nil
    local st = C.RtlDecompressBufferEx(packed_format(format),
                                       out_buf, original_size,
                                       in_buf,  in_len, written, scratch)
    if st ~= 0 then
        error(string.format("xpress.decompress: status=0x%X", st))
    end
    return ffi.string(out_buf, written[0])
end

-- ===== chunked streaming compress ========================================
-- reader: function() -> string|nil       (nil = EOF)
-- writer: function(chunk: string) -> nil
-- Each input chunk is compressed independently and emitted with a
-- 4-byte length prefix so the receiver can recover boundaries. Useful
-- for piping over a pipe / socket without buffering the whole stream.

function M.compress_chunked(reader, writer, format)
    if type(reader) ~= "function" or type(writer) ~= "function" then
        error("xpress.compress_chunked: reader+writer must be functions")
    end
    format = format or M.XPRESS_HUFF
    while true do
        local chunk = reader()
        if chunk == nil then break end
        if #chunk > 0 then
            local comp = M.compress(chunk, format)
            -- Emit: u32 original_len | u32 comp_len | comp_bytes
            local hdr = string.char(
                bit.band(#chunk, 0xFF),
                bit.band(bit.rshift(#chunk, 8),  0xFF),
                bit.band(bit.rshift(#chunk, 16), 0xFF),
                bit.band(bit.rshift(#chunk, 24), 0xFF),
                bit.band(#comp,   0xFF),
                bit.band(bit.rshift(#comp,   8), 0xFF),
                bit.band(bit.rshift(#comp,  16), 0xFF),
                bit.band(bit.rshift(#comp,  24), 0xFF))
            writer(hdr .. comp)
        end
    end
    -- Trailer: all-zero header signals end-of-stream.
    writer(string.char(0,0,0,0, 0,0,0,0))
end

-- ===== framed compress/decompress ========================================
-- Header layout (little-endian):
--   bytes 0..3 : magic 'LVX1'
--   bytes 4..7 : format (u32)
--   bytes 8..11: original length (u32)
-- Then the compressed payload follows.

local function pack_u32(n)
    return string.char(
        bit.band(n, 0xFF),
        bit.band(bit.rshift(n, 8),  0xFF),
        bit.band(bit.rshift(n, 16), 0xFF),
        bit.band(bit.rshift(n, 24), 0xFF))
end

local function unpack_u32(s, off)
    local a, b, c, d = s:byte(off, off + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

function M.frame_compress(bytes, format)
    format = format or M.XPRESS_HUFF
    local comp = M.compress(bytes, format)
    return pack_u32(FRAME_MAGIC) .. pack_u32(format) .. pack_u32(#bytes) .. comp
end

function M.frame_decompress(bytes)
    if type(bytes) ~= "string" or #bytes < FRAME_HDR_SIZE then
        error("xpress.frame_decompress: input too short for header")
    end
    local magic = unpack_u32(bytes, 1)
    if magic ~= FRAME_MAGIC then
        error(string.format("xpress.frame_decompress: bad magic 0x%08X (expected 0x%08X)",
                            magic, FRAME_MAGIC))
    end
    local format        = unpack_u32(bytes, 5)
    local original_size = unpack_u32(bytes, 9)
    local payload       = bytes:sub(FRAME_HDR_SIZE + 1)
    return M.decompress(payload, format, original_size)
end

return M
