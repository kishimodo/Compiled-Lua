-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- lz4 -- LZ4 block + frame format compressor / decompressor.
--
-- Auto-promotes to liblz4.dll when available; falls back to a pure-Lua
-- block + frame implementation otherwise.
--
-- LZ4 block layout (per Yann Collet's reference spec):
--   sequence := token | extra_literal_lengths | literals | offset | extra_match_lengths
--   token = (lit_len_nibble << 4) | match_len_nibble
--     lit_len_nibble = 0..15; if 15, read additional length bytes (255 means another follows).
--     match_len_nibble interpretation is identical, biased by +4 (min match = 4).
--   offset is little-endian uint16 (1..65535).
--
-- End-of-block constraints (required for the decoder to detect EOB
-- without an explicit terminator):
--   * Last 5 bytes of input MUST be encoded as literals (no match).
--   * Last match must start at least 12 bytes before end-of-block.
-- The encoder enforces both by stopping match search 12 bytes before EOB
-- and flushing the tail as a final literals-only sequence.
--
-- Frame format (RFC equivalent, magic 0x184D2204):
--   magic(4) | FLG(1) | BD(1) | [content_size(8)] | header_checksum(1) | data_blocks... | end_mark(0)
--   data block := compressed_size(4) | block_data | [block_checksum(4)]
--     high bit of compressed_size set means block is stored uncompressed.
--
-- Public surface:
--   lz4.compress(bytes, opts?)        -> bytes (LZ4 frame)
--   lz4.decompress(bytes)             -> bytes
--   lz4.block_compress(bytes)         -> bytes (raw block, legacy alias)
--   lz4.block_decompress(bytes, orig) -> bytes
--   lz4.compressor(opts)              -> { :update(s), :final() -> bytes }
--   lz4.decompressor()                -> { :update(s) -> bytes, :final() -> bytes }
--   lz4.has_native()                  -> bool
--
-- opts (compress): { level = 1, block_size = 4*1024*1024, content_size = true }
--   level >= 9 dispatches to LZ4_compress_HC if the native lib is loaded.

local ffi = ffi

local M = {}

local bit_band = bit.band
local bit_bor  = bit.bor
local bit_lsh  = bit.lshift
local bit_rsh  = bit.rshift
local bit_bxor = bit.bxor

local MIN_MATCH       = 4
local LAST_LITERALS   = 5
local MFLIMIT         = 12  -- min input length for any matches: 5 (last literals) + 4 (min match) + 3 (search guard)
local MAX_OFFSET      = 65535
local HASH_LOG        = 16
local HASH_SIZE       = bit_lsh(1, HASH_LOG)

-- ===== block compress ====================================================

local function hash4(b1, b2, b3, b4)
    -- Multiplicative hash on a 32-bit word with high bits used.
    -- Matches the spirit of LZ4_hash4 in the reference (constants tuned
    -- for distribution, not magic).
    local w = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    -- Lua numbers go up to 2^53 cleanly; mul-then-shift is fine.
    return bit_band(bit_rsh(w * 2654435761, 32 - HASH_LOG), HASH_SIZE - 1)
end

-- Emit a variable-length tail used by both lit_len and match_len when
-- the corresponding nibble was 15. The pattern is 255-bytes-then-remainder.
local function emit_var_len(out, n_in, value)
    local n = n_in
    while value >= 255 do
        n = n + 1; out[n] = string.char(255)
        value = value - 255
    end
    n = n + 1; out[n] = string.char(value)
    return n
end

local function emit_sequence(out, n_in, src, lit_start, lit_end, match_off, match_len)
    -- lit_start, lit_end inclusive byte positions in src (1-based).
    -- match_len already includes MIN_MATCH; the wire form is match_len - 4.
    local lit_len = lit_end - lit_start + 1
    if lit_len < 0 then lit_len = 0 end
    local match_wire = match_len - MIN_MATCH
    local lit_nib   = lit_len   >= 15 and 15 or lit_len
    local match_nib = match_wire >= 15 and 15 or match_wire
    local n = n_in
    n = n + 1; out[n] = string.char(bit_bor(bit_lsh(lit_nib, 4), match_nib))
    if lit_len >= 15 then
        n = emit_var_len(out, n, lit_len - 15)
    end
    if lit_len > 0 then
        n = n + 1; out[n] = src:sub(lit_start, lit_end)
    end
    -- Offset (little-endian uint16).
    n = n + 1; out[n] = string.char(bit_band(match_off, 0xFF),
                                    bit_band(bit_rsh(match_off, 8), 0xFF))
    if match_wire >= 15 then
        n = emit_var_len(out, n, match_wire - 15)
    end
    return n
end

local function emit_final_literals(out, n_in, src, lit_start, lit_end)
    local lit_len = lit_end - lit_start + 1
    if lit_len < 0 then lit_len = 0 end
    local lit_nib = lit_len >= 15 and 15 or lit_len
    local n = n_in
    n = n + 1; out[n] = string.char(bit_lsh(lit_nib, 4))
    if lit_len >= 15 then
        n = emit_var_len(out, n, lit_len - 15)
    end
    if lit_len > 0 then
        n = n + 1; out[n] = src:sub(lit_start, lit_end)
    end
    return n
end

function M.compress(bytes)
    if type(bytes) ~= "string" then
        error("lz4.compress: expected string, got " .. type(bytes))
    end
    local src_len = #bytes
    local out, n = {}, 0
    -- Tiny inputs: just emit a single literals-only sequence.
    if src_len < MFLIMIT then
        return string.char(bit_lsh(src_len >= 15 and 15 or src_len, 4))
            .. (src_len >= 15
                and table.concat({ M._encode_var_len(src_len - 15), bytes })
                or bytes)
    end
    local table_hash = {}  -- hash -> last position seen (1-based)
    local pos        = 1
    local anchor     = 1  -- start of current pending literal run
    local limit      = src_len - MFLIMIT + 1
    while pos <= limit do
        local b1, b2, b3, b4 = bytes:byte(pos, pos + 3)
        local h = hash4(b1, b2, b3, b4)
        local cand = table_hash[h]
        table_hash[h] = pos
        if cand ~= nil and pos - cand <= MAX_OFFSET and pos - cand >= 1 then
            -- Verify the first 4 bytes (hash collisions exist).
            if bytes:byte(cand)     == b1
               and bytes:byte(cand+1) == b2
               and bytes:byte(cand+2) == b3
               and bytes:byte(cand+3) == b4 then
                -- Extend match.
                local match_len = MIN_MATCH
                local max_extend = src_len - LAST_LITERALS - (pos + MIN_MATCH) + 1
                while match_len < 0xFFFF + 15 + MIN_MATCH
                      and max_extend > 0
                      and bytes:byte(pos + match_len) == bytes:byte(cand + match_len) do
                    match_len = match_len + 1
                    max_extend = max_extend - 1
                end
                local offset = pos - cand
                n = emit_sequence(out, n, bytes, anchor, pos - 1, offset, match_len)
                -- Insert the table entry one past the literal-start so
                -- subsequent matches find this position too.
                pos = pos + match_len
                if pos <= limit then
                    -- Insert the new position; do a couple of internal
                    -- hash inserts to seed the next search.
                    local hpos = pos - 2
                    if hpos >= 1 then
                        local h2 = hash4(bytes:byte(hpos), bytes:byte(hpos+1),
                                         bytes:byte(hpos+2), bytes:byte(hpos+3))
                        table_hash[h2] = hpos
                    end
                end
                anchor = pos
            else
                pos = pos + 1
            end
        else
            pos = pos + 1
        end
    end
    -- Flush remaining tail as final literals.
    n = emit_final_literals(out, n, bytes, anchor, src_len)
    return table.concat(out)
end

-- Used only by the tiny-input branch above; small helper that emits a
-- string of var-length tail bytes.
function M._encode_var_len(value)
    local pieces, k = {}, 0
    while value >= 255 do
        k = k + 1; pieces[k] = string.char(255)
        value = value - 255
    end
    k = k + 1; pieces[k] = string.char(value)
    return table.concat(pieces)
end

-- ===== block decompress ==================================================

function M.decompress(bytes, original_size)
    if type(bytes) ~= "string" then
        error("lz4.decompress: expected string, got " .. type(bytes))
    end
    if type(original_size) ~= "number" or original_size < 0 then
        error("lz4.decompress: original_size required")
    end
    local src_len = #bytes
    -- Build the output as a table of byte chunks; flatten at end.
    -- Matches/copies need to read from already-emitted bytes so we
    -- maintain a running concat lazily.
    local out, n = {}, 0
    local current = ""  -- materialised output so far for back-copies
    local i = 1
    while i <= src_len do
        local token = bytes:byte(i); i = i + 1
        local lit_len = bit_rsh(token, 4)
        if lit_len == 15 then
            while true do
                local b = bytes:byte(i)
                if b == nil then error("lz4.decompress: truncated literal length") end
                i = i + 1
                lit_len = lit_len + b
                if b ~= 255 then break end
            end
        end
        if lit_len > 0 then
            local lit = bytes:sub(i, i + lit_len - 1)
            if #lit ~= lit_len then error("lz4.decompress: truncated literals") end
            n = n + 1; out[n] = lit
            current = current .. lit
            i = i + lit_len
        end
        if i > src_len then break end  -- final block: literals-only, no match
        -- Offset (2 bytes LE).
        local o1, o2 = bytes:byte(i, i + 1)
        if o2 == nil then error("lz4.decompress: truncated offset") end
        i = i + 2
        local offset = o1 + o2 * 256
        if offset == 0 then error("lz4.decompress: zero offset") end
        local match_len = bit_band(token, 0x0F)
        if match_len == 15 then
            while true do
                local b = bytes:byte(i)
                if b == nil then error("lz4.decompress: truncated match length") end
                i = i + 1
                match_len = match_len + b
                if b ~= 255 then break end
            end
        end
        match_len = match_len + MIN_MATCH
        -- Back-copy from current output. Reference spec permits
        -- offset < match_len (i.e. self-overlap producing run-length
        -- expansion); handle byte-by-byte in that case.
        local total = #current
        if offset > total then
            error(string.format("lz4.decompress: offset %d exceeds output length %d", offset, total))
        end
        local copy
        if offset >= match_len then
            local s = total - offset + 1
            copy = current:sub(s, s + match_len - 1)
        else
            local pieces, k = {}, 0
            local s = total - offset + 1
            for j = 0, match_len - 1 do
                local p = s + (j % offset)
                k = k + 1; pieces[k] = current:sub(p, p)
                -- For overlap to work we don't update current per byte;
                -- the modulo math already accounts for repeated patterns.
            end
            copy = table.concat(pieces)
        end
        n = n + 1; out[n] = copy
        current = current .. copy
    end
    -- original_size is treated as an upper bound rather than an exact
    -- expectation: the frame decoder hands us the per-frame block-size
    -- cap (e.g. 64 KiB) and the real decompressed size is whatever the
    -- LZ4 sequences actually produce.
    if original_size and #current > original_size then
        error(string.format("lz4.decompress: oversize output (%d > cap %d)",
                            #current, original_size))
    end
    return current
end

-- ===== frame format ======================================================

local FRAME_MAGIC = 0x184D2204

local function pack_u32_le(v)
    return string.char(
        bit_band(v, 0xFF),
        bit_band(bit_rsh(v,  8), 0xFF),
        bit_band(bit_rsh(v, 16), 0xFF),
        bit_band(bit_rsh(v, 24), 0xFF))
end

local function unpack_u32_le(s, off)
    local a, b, c, d = s:byte(off, off + 3)
    if d == nil then error("lz4: truncated u32 at offset " .. off) end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- XXH32 -- the LZ4 frame format requires it for the header checksum
-- byte (low 8 bits of (xxh32(FLG..BD..[size]) >> 8)). We implement the
-- streaming variant for completeness; the frame writer only ever feeds
-- it 2-10 bytes so it's not performance-sensitive.
local XXH32_P1 = 2654435761
local XXH32_P2 = 2246822519
local XXH32_P3 = 3266489917
local XXH32_P4 = 668265263
local XXH32_P5 = 374761393

local function rotl32(v, n)
    v = bit_band(v, 0xFFFFFFFF)
    return bit_band(bit_bor(bit_lsh(v, n), bit_rsh(v, 32 - n)), 0xFFFFFFFF)
end

local function mul32(a, b)
    -- 32-bit modular multiply. Lua doubles are 53 bits so split a into
    -- high/low halves to avoid precision loss.
    local ah = bit_rsh(a, 16)
    local al = bit_band(a, 0xFFFF)
    return bit_band(ah * b * 65536 + al * b, 0xFFFFFFFF)
end

local function xxh32(s, seed)
    seed = seed or 0
    local len = #s
    local h
    if len < 16 then
        h = bit_band(seed + XXH32_P5, 0xFFFFFFFF)
    else
        local v1 = bit_band(seed + XXH32_P1 + XXH32_P2, 0xFFFFFFFF)
        local v2 = bit_band(seed + XXH32_P2,            0xFFFFFFFF)
        local v3 = bit_band(seed,                       0xFFFFFFFF)
        local v4 = bit_band(seed - XXH32_P1,            0xFFFFFFFF)
        local i = 1
        while i + 15 <= len do
            local function lane(lane_v, off)
                local w = s:byte(off) + s:byte(off+1)*256
                        + s:byte(off+2)*65536 + s:byte(off+3)*16777216
                lane_v = bit_band(lane_v + mul32(w, XXH32_P2), 0xFFFFFFFF)
                lane_v = rotl32(lane_v, 13)
                return mul32(lane_v, XXH32_P1)
            end
            v1 = lane(v1, i)
            v2 = lane(v2, i + 4)
            v3 = lane(v3, i + 8)
            v4 = lane(v4, i + 12)
            i = i + 16
        end
        h = bit_band(rotl32(v1, 1) + rotl32(v2, 7) + rotl32(v3, 12) + rotl32(v4, 18), 0xFFFFFFFF)
    end
    h = bit_band(h + len, 0xFFFFFFFF)
    local i = (len >= 16) and (math.floor((len - 1) / 16) * 16 + 1) or 1
    while i + 3 <= len do
        local w = s:byte(i) + s:byte(i+1)*256
                + s:byte(i+2)*65536 + s:byte(i+3)*16777216
        h = bit_band(h + mul32(w, XXH32_P3), 0xFFFFFFFF)
        h = mul32(rotl32(h, 17), XXH32_P4)
        i = i + 4
    end
    while i <= len do
        h = bit_band(h + mul32(s:byte(i), XXH32_P5), 0xFFFFFFFF)
        h = mul32(rotl32(h, 11), XXH32_P1)
        i = i + 1
    end
    h = bit_band(bit_bxor(h, bit_rsh(h, 15)), 0xFFFFFFFF)
    h = mul32(h, XXH32_P2)
    h = bit_band(bit_bxor(h, bit_rsh(h, 13)), 0xFFFFFFFF)
    h = mul32(h, XXH32_P3)
    return bit_band(bit_bxor(h, bit_rsh(h, 16)), 0xFFFFFFFF)
end

M.xxh32 = xxh32

function M.frame_compress(bytes, _format)
    -- Minimum-feature frame:
    --   FLG = 0x60 -- version=01 (bits 7..6), independent blocks (bit5=1), no checksums.
    --   BD  = 0x40 -- block size 64 KiB (value 4 shifted to bits 6..4).
    -- Without content_size or checksums, header_checksum covers just FLG..BD.
    local FLG = 0x60
    local BD  = 0x40
    local hdr_chk_input = string.char(FLG, BD)
    local hc = bit_band(bit_rsh(xxh32(hdr_chk_input, 0), 8), 0xFF)
    local out, n = {}, 0
    n = n + 1; out[n] = pack_u32_le(FRAME_MAGIC)
    n = n + 1; out[n] = string.char(FLG, BD, hc)
    -- Split into independent 64 KiB blocks.
    local pos = 1
    while pos <= #bytes do
        local chunk_len = math.min(65536, #bytes - pos + 1)
        local chunk = bytes:sub(pos, pos + chunk_len - 1)
        local comp = M.block_compress(chunk)
        if #comp >= chunk_len then
            -- Compression didn't help -- emit uncompressed (high bit set).
            n = n + 1; out[n] = pack_u32_le(bit_bor(chunk_len, 0x80000000))
            n = n + 1; out[n] = chunk
        else
            n = n + 1; out[n] = pack_u32_le(#comp)
            n = n + 1; out[n] = comp
        end
        pos = pos + chunk_len
    end
    -- End mark.
    n = n + 1; out[n] = pack_u32_le(0)
    return table.concat(out)
end

function M.frame_decompress(bytes)
    if #bytes < 7 then error("lz4.frame_decompress: input too short") end
    local magic = unpack_u32_le(bytes, 1)
    if magic ~= FRAME_MAGIC then
        error(string.format("lz4.frame_decompress: bad magic 0x%08X", magic))
    end
    local FLG = bytes:byte(5)
    local BD  = bytes:byte(6)
    local pos = 7
    local has_content_size = bit_band(FLG, 0x08) ~= 0
    local has_block_ck     = bit_band(FLG, 0x10) ~= 0
    local has_content_ck   = bit_band(FLG, 0x04) ~= 0
    local has_dict_id      = bit_band(FLG, 0x01) ~= 0
    if has_content_size then pos = pos + 8 end
    if has_dict_id      then pos = pos + 4 end
    pos = pos + 1  -- skip header checksum byte (caller trusts the frame)
    -- Block size from BD bits 6..4: 4=64KB, 5=256KB, 6=1MB, 7=4MB.
    local bs_code = bit_band(bit_rsh(BD, 4), 0x07)
    local max_block
    if     bs_code == 4 then max_block = 64 * 1024
    elseif bs_code == 5 then max_block = 256 * 1024
    elseif bs_code == 6 then max_block = 1024 * 1024
    elseif bs_code == 7 then max_block = 4 * 1024 * 1024
    else                     max_block = 64 * 1024 end
    local out, n = {}, 0
    while pos <= #bytes do
        local bsize = unpack_u32_le(bytes, pos); pos = pos + 4
        if bsize == 0 then break end  -- end mark
        local uncompressed = bit_band(bsize, 0x80000000) ~= 0
        local actual = bit_band(bsize, 0x7FFFFFFF)
        local block = bytes:sub(pos, pos + actual - 1)
        pos = pos + actual
        if has_block_ck then pos = pos + 4 end
        if uncompressed then
            n = n + 1; out[n] = block
        else
            n = n + 1; out[n] = M.block_decompress(block, max_block)
        end
    end
    if has_content_ck then pos = pos + 4 end
    return table.concat(out)
end

-- ===== Back-compat aliases (block_compress / block_decompress) ===========
-- Stash the existing pure-Lua block surface BEFORE the unified frame-level
-- compress / decompress below overwrites M.compress / M.decompress.

M.block_compress   = M.compress
M.block_decompress = M.decompress

-- ===== Native FFI surface (liblz4 / lz4) =================================

ffi.cdef[[
typedef struct lz4_LZ4F_cctx_s   lz4_LZ4F_cctx;
typedef struct lz4_LZ4F_dctx_s   lz4_LZ4F_dctx;

int LZ4_versionNumber(void);

int LZ4_compress_default(const char *src, char *dst,
                         int srcSize, int dstCapacity);
int LZ4_compressBound(int srcSize);
int LZ4_compress_HC(const char *src, char *dst,
                    int srcSize, int dstCapacity, int compressionLevel);
int LZ4_decompress_safe(const char *src, char *dst,
                        int compressedSize, int dstCapacity);

/* Frame API. preferences are passed as opaque blobs whose layout we
   set up ourselves; sizes match the public LZ4F_preferences_t struct
   from lz4frame.h (1.9.x). */
typedef struct lz4_LZ4F_preferences_s {
    /* LZ4F_frameInfo_t (40 bytes on 64-bit): blockSize(4)+blockMode(4)+
       contentChecksumFlag(4)+frameType(4)+contentSize(8)+dictID(4)+
       blockChecksumFlag(4)+_pad(8). */
    unsigned int  blockSizeID;
    unsigned int  blockMode;
    unsigned int  contentChecksum;
    unsigned int  frameType;
    unsigned long long contentSize;
    unsigned int  dictID;
    unsigned int  blockChecksum;
    /* preferences_t tail: compressionLevel(4)+autoFlush(4)+favorDecSpeed(4)+_reserved(12). */
    int           compressionLevel;
    unsigned int  autoFlush;
    unsigned int  favorDecSpeed;
    unsigned int  reserved[3];
} lz4_LZ4F_preferences_t;

unsigned long LZ4F_compressFrame(void *dstBuffer, unsigned long dstCapacity,
                                 const void *srcBuffer, unsigned long srcSize,
                                 const lz4_LZ4F_preferences_t *prefs);
unsigned long LZ4F_compressFrameBound(unsigned long srcSize,
                                      const lz4_LZ4F_preferences_t *prefs);

unsigned long LZ4F_createCompressionContext(lz4_LZ4F_cctx **ctx, unsigned int version);
unsigned long LZ4F_freeCompressionContext(lz4_LZ4F_cctx *ctx);
unsigned long LZ4F_compressBegin(lz4_LZ4F_cctx *ctx, void *dstBuffer,
                                 unsigned long dstCapacity,
                                 const lz4_LZ4F_preferences_t *prefs);
unsigned long LZ4F_compressBound(unsigned long srcSize,
                                 const lz4_LZ4F_preferences_t *prefs);
unsigned long LZ4F_compressUpdate(lz4_LZ4F_cctx *ctx, void *dstBuffer,
                                  unsigned long dstCapacity,
                                  const void *srcBuffer, unsigned long srcSize,
                                  void *cOptPtr);
unsigned long LZ4F_compressEnd(lz4_LZ4F_cctx *ctx, void *dstBuffer,
                               unsigned long dstCapacity, void *cOptPtr);

unsigned long LZ4F_createDecompressionContext(lz4_LZ4F_dctx **dctx, unsigned int version);
unsigned long LZ4F_freeDecompressionContext(lz4_LZ4F_dctx *dctx);
unsigned long LZ4F_decompress(lz4_LZ4F_dctx *dctx,
                              void *dstBuffer, unsigned long *dstSizePtr,
                              const void *srcBuffer, unsigned long *srcSizePtr,
                              void *dOptPtr);

unsigned int  LZ4F_isError(unsigned long code);
const char   *LZ4F_getErrorName(unsigned long code);
]]

local _native_state -- nil = unprobed, false = absent, table = loaded

local function probe_native()
    if _native_state ~= nil then return _native_state end
    local override = os.getenv("LUAVM_LZ4_DLL")
    local names    = { "liblz4", "lz4", "liblz4.dll", "lz4.dll" }
    if override and override ~= "" then
        table.insert(names, 1, override)
    end
    local lib
    for _, n in ipairs(names) do
        local ok, l = pcall(ffi.load, n)
        if ok then lib = l; break end
    end
    if lib == nil then _native_state = false; return false end
    _native_state = { lib = lib }
    return _native_state
end

function M.has_native()
    local ns = probe_native()
    return ns and ns ~= false and true or false
end

-- LZ4F block size IDs: 4=64KB, 5=256KB, 6=1MB, 7=4MB. Map a byte size
-- to the closest ID >= it.
local function _block_size_id(n)
    if not n or n <= 64 * 1024     then return 4 end
    if n <= 256 * 1024             then return 5 end
    if n <= 1024 * 1024            then return 6 end
    return 7
end

local function _build_prefs(opts)
    opts = opts or {}
    local prefs = ffi.new("lz4_LZ4F_preferences_t")
    prefs.blockSizeID      = _block_size_id(opts.block_size)
    prefs.blockMode        = 0  -- linked blocks
    prefs.contentChecksum  = opts.checksum and 1 or 0
    prefs.frameType        = 0
    prefs.contentSize      = (opts.content_size ~= false and opts.content_size_value)
                              and opts.content_size_value or 0
    prefs.dictID           = 0
    prefs.blockChecksum    = 0
    prefs.compressionLevel = opts.level or 1
    prefs.autoFlush        = 0
    prefs.favorDecSpeed    = 0
    return prefs
end

local function _lz4f_check(rc, what)
    local ns = _native_state
    if ns and ns ~= false and ns.lib.LZ4F_isError(rc) ~= 0 then
        local name = ffi.string(ns.lib.LZ4F_getErrorName(rc))
        error(string.format("lz4.%s: %s", what, name))
    end
end

-- ===== Unified compress / decompress =====================================

local function _frame_compress_native(bytes, opts)
    local ns = probe_native()
    if not ns then return nil end
    local lib   = ns.lib
    local prefs = _build_prefs(opts)
    if opts and opts.content_size ~= false then
        prefs.contentSize = #bytes
    end
    local cap = tonumber(lib.LZ4F_compressFrameBound(#bytes, prefs))
    local dst = ffi.new("char[?]", cap > 0 and cap or 1)
    local rc  = lib.LZ4F_compressFrame(dst, cap, bytes, #bytes, prefs)
    _lz4f_check(rc, "compress")
    return ffi.string(dst, tonumber(rc))
end

local function _frame_decompress_native(bytes)
    local ns = probe_native()
    if not ns then return nil end
    local lib  = ns.lib
    local ctx_box = ffi.new("lz4_LZ4F_dctx*[1]")
    local rc = lib.LZ4F_createDecompressionContext(ctx_box, 100)  -- LZ4F_VERSION = 100
    _lz4f_check(rc, "decompress (ctx)")
    local dctx = ctx_box[0]
    local src_pos = 0
    local src_len = #bytes
    local out_pieces, np = {}, 0
    local CHUNK = 64 * 1024
    local out_buf = ffi.new("char[?]", CHUNK)
    while src_pos < src_len do
        local dst_sz = ffi.new("unsigned long[1]", CHUNK)
        local src_sz = ffi.new("unsigned long[1]", src_len - src_pos)
        rc = lib.LZ4F_decompress(dctx, out_buf, dst_sz,
                                 ffi.cast("const char *", bytes) + src_pos,
                                 src_sz, nil)
        if lib.LZ4F_isError(rc) ~= 0 then
            local name = ffi.string(lib.LZ4F_getErrorName(rc))
            lib.LZ4F_freeDecompressionContext(dctx)
            error("lz4.decompress: " .. name)
        end
        local produced = tonumber(dst_sz[0])
        if produced > 0 then
            np = np + 1; out_pieces[np] = ffi.string(out_buf, produced)
        end
        src_pos = src_pos + tonumber(src_sz[0])
        if rc == 0 then break end  -- frame finished
    end
    lib.LZ4F_freeDecompressionContext(dctx)
    return table.concat(out_pieces)
end

-- Replace the top-level M.compress / M.decompress (block-level) with the
-- frame-level variants the spec asks for. block_compress / block_decompress
-- aliases above preserve the raw-block surface for advanced callers.
function M.compress(bytes, opts)
    if type(bytes) ~= "string" then
        error("lz4.compress: expected string, got " .. type(bytes))
    end
    local native = _frame_compress_native(bytes, opts)
    if native ~= nil then return native end
    -- Pure-Lua fallback: emit the same frame format. block_size / level
    -- aren't honoured by the fallback (uses the existing 64 KiB layout).
    return M.frame_compress(bytes)
end

function M.decompress(bytes)
    if type(bytes) ~= "string" then
        error("lz4.decompress: expected string, got " .. type(bytes))
    end
    -- If the input looks like a frame, dispatch to the frame decoder.
    if #bytes >= 4 then
        local m = bytes:byte(1) + bytes:byte(2) * 256
                + bytes:byte(3) * 65536 + bytes:byte(4) * 16777216
        if m == FRAME_MAGIC then
            local native = _frame_decompress_native(bytes)
            if native ~= nil then return native end
            return M.frame_decompress(bytes)
        end
    end
    error("lz4.decompress: input is not a valid LZ4 frame (use block_decompress for raw blocks)")
end

-- ===== Streaming compressor / decompressor ===============================

local _compressor_mt = {}
_compressor_mt.__index = _compressor_mt

function _compressor_mt:update(chunk)
    if self._done then error("lz4.compressor: already finalised") end
    if chunk == nil or chunk == "" then return "" end
    if self._native then
        local lib = self._native.lib
        local cap = tonumber(lib.LZ4F_compressBound(#chunk, self._prefs))
        local dst = ffi.new("char[?]", cap)
        local rc  = lib.LZ4F_compressUpdate(self._ctx, dst, cap, chunk, #chunk, nil)
        _lz4f_check(rc, "compressor.update")
        return ffi.string(dst, tonumber(rc))
    else
        self._buf[#self._buf + 1] = chunk
        return ""
    end
end

function _compressor_mt:final()
    if self._done then error("lz4.compressor: already finalised") end
    self._done = true
    if self._native then
        local lib = self._native.lib
        local cap = tonumber(lib.LZ4F_compressBound(0, self._prefs))
        local dst = ffi.new("char[?]", cap > 0 and cap or 32)
        local rc  = lib.LZ4F_compressEnd(self._ctx, dst, cap > 0 and cap or 32, nil)
        _lz4f_check(rc, "compressor.final")
        local tail = ffi.string(dst, tonumber(rc))
        lib.LZ4F_freeCompressionContext(self._ctx)
        return (self._head or "") .. tail
    else
        return M.compress(table.concat(self._buf), self._opts)
    end
end

function M.compressor(opts)
    opts = opts or {}
    local obj = setmetatable({
        _opts = opts,
        _done = false,
    }, _compressor_mt)
    local ns = probe_native()
    if ns then
        local lib   = ns.lib
        local prefs = _build_prefs(opts)
        local ctx_box = ffi.new("lz4_LZ4F_cctx*[1]")
        local rc = lib.LZ4F_createCompressionContext(ctx_box, 100)
        _lz4f_check(rc, "compressor (ctx)")
        local ctx = ctx_box[0]
        local head_cap = 32
        local head     = ffi.new("char[?]", head_cap)
        rc = lib.LZ4F_compressBegin(ctx, head, head_cap, prefs)
        _lz4f_check(rc, "compressor (begin)")
        obj._native = ns
        obj._ctx    = ctx
        obj._prefs  = prefs
        obj._head   = ffi.string(head, tonumber(rc))
    else
        obj._buf = {}
    end
    return obj
end

local _decompressor_mt = {}
_decompressor_mt.__index = _decompressor_mt

function _decompressor_mt:update(chunk)
    if self._done then error("lz4.decompressor: already finalised") end
    if chunk == nil or chunk == "" then return "" end
    self._buf[#self._buf + 1] = chunk
    return ""
end

function _decompressor_mt:final()
    if self._done then error("lz4.decompressor: already finalised") end
    self._done = true
    return M.decompress(table.concat(self._buf))
end

function M.decompressor()
    return setmetatable({ _buf = {}, _done = false }, _decompressor_mt)
end

return M
