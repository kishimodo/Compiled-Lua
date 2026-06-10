-- hash -- unified streaming + one-shot hash API.
--
-- Algorithms:
--   md5, sha1, sha256, sha384, sha512        (Windows CNG BCrypt)
--   sha3_256, sha3_384, sha3_512             (CNG; requires Windows 10 1903 or newer)
--   crc32                                    (table-driven, pure Lua)
--   xxhash32, xxhash64                       (full XXH spec, pure Lua)
--   blake3                                   (full BLAKE3 with chunk tree, pure Lua)
--
-- Public surface:
--   hash.new(algo)                  -> ctx with :update(s), :digest(), :hexdigest(), :reset()
--   hash.<algo>(s)                  -> lowercase hex digest (one-shot)
--   hash.<algo>_raw(s)              -> raw digest bytes
--   hash.<algo>_hex(s)              -> alias for hash.<algo>(s) (RFC-style hex)
--   hash.file(algo, path[, chunk])  -> hex digest of a file, streamed (default 64 KiB chunks)
--   hash.file_raw(algo, path[, chunk])
--   hash.algorithms                 -> array of supported names
--   hash.digest_size(algo)          -> bytes
--   hash.block_size(algo)           -> bytes (HMAC needs this)
--
-- Bytes everywhere are Lua strings (8-bit clean).
-- The streaming ctx also exposes :update(data) -> self, :final()/:final_hex()
-- as legacy aliases for :digest()/:hexdigest().

require "windows"
local BC = require "windows.bcrypt"

local M = {}

-- ===== Sizing tables (digest + HMAC block size) ========================

local DIGEST_SIZE = {
    md5      = 16,
    sha1     = 20,
    sha256   = 32,
    sha384   = 48,
    sha512   = 64,
    sha3_256 = 32,
    sha3_384 = 48,
    sha3_512 = 64,
    crc32    = 4,
    xxhash32 = 4,
    xxhash64 = 8,
    blake3   = 32,
}

local BLOCK_SIZE = {
    md5      = 64,
    sha1     = 64,
    sha256   = 64,
    sha384   = 128,
    sha512   = 128,
    sha3_256 = 136,    -- SHA-3 rate r = 1600 - 2*256 bits = 136 bytes
    sha3_384 = 104,
    sha3_512 = 72,
    crc32    = 4,
    xxhash32 = 16,
    xxhash64 = 32,
    blake3   = 64,
}

function M.digest_size(algo) return DIGEST_SIZE[algo] end
function M.block_size(algo)  return BLOCK_SIZE[algo]  end

M.algorithms = {
    "md5", "sha1", "sha256", "sha384", "sha512",
    "sha3_256", "sha3_384", "sha3_512",
    "crc32", "xxhash32", "xxhash64", "blake3",
}

-- ===== Hex helper ======================================================

local _hex_lut = {}
for i = 0, 255 do _hex_lut[i] = string.format("%02x", i) end

local function to_hex(s)
    local n = #s
    local out, j = {}, 0
    for i = 1, n do
        j = j + 1; out[j] = _hex_lut[s:byte(i)]
    end
    return table.concat(out)
end
M.to_hex = to_hex

-- ===== CNG (BCrypt) backend ============================================

local _bcrypt_alg_handles = {}  -- algo name -> opened BCRYPT_ALG_HANDLE

local function bcrypt_open(name_buf)
    local h = ffi.new("PVOID[1]")
    local status = ffi.C.BCryptOpenAlgorithmProvider(h, name_buf, nil, 0)
    if status ~= 0 then
        error(string.format("hash: BCryptOpenAlgorithmProvider failed 0x%08X", status))
    end
    return h[0]
end

local function get_alg_handle(algo)
    local h = _bcrypt_alg_handles[algo]
    if h ~= nil then return h end
    local name
    if     algo == "md5"      then name = BC.MD5_ALGORITHM
    elseif algo == "sha1"     then name = BC.SHA1_ALGORITHM
    elseif algo == "sha256"   then name = BC.SHA256_ALGORITHM
    elseif algo == "sha384"   then name = BC.SHA384_ALGORITHM
    elseif algo == "sha512"   then name = BC.SHA512_ALGORITHM
    elseif algo == "sha3_256" then name = BC.SHA3_256_ALGORITHM
    elseif algo == "sha3_384" then name = BC.SHA3_384_ALGORITHM
    elseif algo == "sha3_512" then name = BC.SHA3_512_ALGORITHM
    else error("hash: unknown CNG algorithm '" .. tostring(algo) .. "'") end
    h = bcrypt_open(name)
    _bcrypt_alg_handles[algo] = h
    return h
end

-- Probe whether CNG actually supports an algorithm on this host.
-- SHA-3 is only available from Windows 10 1903 onwards; on older systems
-- BCryptOpenAlgorithmProvider fails and we fall back to a pure-Lua impl.
local _cng_unavailable = {}
local function cng_has(algo)
    if _cng_unavailable[algo] then return false end
    if _bcrypt_alg_handles[algo] ~= nil then return true end
    local ok = pcall(get_alg_handle, algo)
    if not ok then _cng_unavailable[algo] = true end
    return ok
end

local function bcrypt_new_ctx(algo)
    local alg = get_alg_handle(algo)
    local hh = ffi.new("PVOID[1]")
    local status = ffi.C.BCryptCreateHash(alg, hh, nil, 0, nil, 0, 0)
    if status ~= 0 then
        error(string.format("hash: BCryptCreateHash failed 0x%08X", status))
    end
    return ffi.gc(hh[0], ffi.C.BCryptDestroyHash), alg
end

local CngHash = {}
CngHash.__index = CngHash

function CngHash:update(s)
    if type(s) ~= "string" then error("hash:update expects string") end
    if self._done then error("hash:update called after :final (call :reset first)") end
    if #s == 0 then return self end
    local buf = ffi.cast("PVOID", s)
    local status = ffi.C.BCryptHashData(self._h, buf, #s, 0)
    if status ~= 0 then
        error(string.format("hash: BCryptHashData failed 0x%08X", status))
    end
    return self
end

function CngHash:final()
    if self._done then return self._digest end
    local sz = DIGEST_SIZE[self._algo]
    local out = ffi.new("unsigned char[?]", sz)
    local status = ffi.C.BCryptFinishHash(self._h, out, sz, 0)
    if status ~= 0 then
        error(string.format("hash: BCryptFinishHash failed 0x%08X", status))
    end
    self._digest = ffi.string(out, sz)
    self._done = true
    -- Handle is now spent; release early.
    ffi.C.BCryptDestroyHash(ffi.gc(self._h, nil))
    self._h = nil
    return self._digest
end

function CngHash:final_hex() return to_hex(self:final()) end

-- Modern aliases preferred by the spec.
CngHash.digest    = CngHash.final
CngHash.hexdigest = CngHash.final_hex

function CngHash:reset()
    if self._h ~= nil then
        ffi.C.BCryptDestroyHash(ffi.gc(self._h, nil))
    end
    -- bcrypt_new_ctx returns (handle, alg) -- we only keep the hash handle.
    self._h, _ = bcrypt_new_ctx(self._algo)
    self._done = false
    self._digest = nil
    return self
end

local function cng_new(algo)
    local h, _ = bcrypt_new_ctx(algo)
    return setmetatable({ _h = h, _algo = algo, _done = false }, CngHash)
end

-- ===== CRC32 (IEEE 802.3 polynomial 0xEDB88320) ========================

local _crc32_tbl = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if (c & 1) ~= 0 then
            c = (c >> 1) ~ 0xEDB88320
        else
            c = c >> 1
        end
    end
    _crc32_tbl[i] = c
end

local Crc32 = {}
Crc32.__index = Crc32

function Crc32:update(s)
    if type(s) ~= "string" then error("hash:update expects string") end
    local c = self._c
    local tbl = _crc32_tbl
    for i = 1, #s do
        c = (c >> 8) ~ tbl[(c ~ s:byte(i)) & 0xFF]
    end
    self._c = c
    return self
end

function Crc32:final()
    -- Big-endian 4-byte digest of the final XOR'd CRC.
    local v = (~self._c) & 0xFFFFFFFF
    return string.char(
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >>  8) & 0xFF,
         v        & 0xFF)
end

function Crc32:final_hex() return to_hex(self:final()) end

Crc32.digest    = Crc32.final
Crc32.hexdigest = Crc32.final_hex

function Crc32:value()
    -- Convenience: return CRC as an unsigned 32-bit integer.
    return (~self._c) & 0xFFFFFFFF
end

function Crc32:reset()
    self._c = 0xFFFFFFFF
    return self
end

local function crc32_new()
    return setmetatable({ _c = 0xFFFFFFFF }, Crc32)
end

-- ===== xxHash64 (XXH64, official spec) =================================
-- Reference: https://github.com/Cyan4973/xxHash
-- Uses LuaJIT/Lua 5.4 64-bit integer arithmetic.

local XXH64_P1 = 0x9E3779B185EBCA87
local XXH64_P2 = 0xC2B2AE3D27D4EB4F
local XXH64_P3 = 0x165667B19E3779F9
local XXH64_P4 = 0x85EBCA77C2B2AE63
local XXH64_P5 = 0x27D4EB2F165667C5

local MASK64 = 0xFFFFFFFFFFFFFFFF

local function rotl64(x, r)
    x = x & MASK64
    return ((x << r) | (x >> (64 - r))) & MASK64
end

local function xxh64_round(acc, lane)
    acc = (acc + (lane * XXH64_P2)) & MASK64
    acc = rotl64(acc, 31)
    return (acc * XXH64_P1) & MASK64
end

local function xxh64_merge(acc, lane)
    lane = xxh64_round(0, lane)
    acc = (acc ~ lane) & MASK64
    return ((acc * XXH64_P1) + XXH64_P4) & MASK64
end

local function read_u64_le(s, i)
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(i, i + 7)
    return b1
        | (b2 << 8)  | (b3 << 16) | (b4 << 24)
        | (b5 << 32) | (b6 << 40) | (b7 << 48) | (b8 << 56)
end

local function read_u32_le(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
end

local XxHash64 = {}
XxHash64.__index = XxHash64

function XxHash64:update(s)
    if type(s) ~= "string" then error("hash:update expects string") end
    self._total = self._total + #s
    -- Append to a small carry buffer until we have at least one 32-byte stripe.
    if self._buf ~= "" then
        s = self._buf .. s
        self._buf = ""
    end
    local pos, len = 1, #s
    if self._v == nil and len >= 32 then
        -- First time we see a full stripe -- initialize accumulators.
        self._v = {
            (self._seed + XXH64_P1 + XXH64_P2) & MASK64,
            (self._seed + XXH64_P2)             & MASK64,
             self._seed,
            (self._seed - XXH64_P1)             & MASK64,
        }
    end
    while pos + 31 <= len do
        local v = self._v
        v[1] = xxh64_round(v[1], read_u64_le(s, pos))
        v[2] = xxh64_round(v[2], read_u64_le(s, pos +  8))
        v[3] = xxh64_round(v[3], read_u64_le(s, pos + 16))
        v[4] = xxh64_round(v[4], read_u64_le(s, pos + 24))
        pos = pos + 32
    end
    if pos <= len then
        self._buf = s:sub(pos)
    end
    return self
end

function XxHash64:value()
    local h
    if self._v ~= nil then
        local v = self._v
        h = (rotl64(v[1], 1) + rotl64(v[2], 7) + rotl64(v[3], 12) + rotl64(v[4], 18)) & MASK64
        h = xxh64_merge(h, v[1])
        h = xxh64_merge(h, v[2])
        h = xxh64_merge(h, v[3])
        h = xxh64_merge(h, v[4])
    else
        h = (self._seed + XXH64_P5) & MASK64
    end
    h = (h + self._total) & MASK64
    local rem = self._buf
    local i, n = 1, #rem
    while i + 7 <= n do
        h = (h ~ xxh64_round(0, read_u64_le(rem, i))) & MASK64
        h = ((rotl64(h, 27) * XXH64_P1) + XXH64_P4) & MASK64
        i = i + 8
    end
    if i + 3 <= n then
        h = (h ~ ((read_u32_le(rem, i) * XXH64_P1) & MASK64)) & MASK64
        h = ((rotl64(h, 23) * XXH64_P2) + XXH64_P3) & MASK64
        i = i + 4
    end
    while i <= n do
        h = (h ~ ((rem:byte(i) * XXH64_P5) & MASK64)) & MASK64
        h = (rotl64(h, 11) * XXH64_P1) & MASK64
        i = i + 1
    end
    -- Avalanche
    h = (h ~ (h >> 33)) & MASK64
    h = (h * XXH64_P2)  & MASK64
    h = (h ~ (h >> 29)) & MASK64
    h = (h * XXH64_P3)  & MASK64
    h = (h ~ (h >> 32)) & MASK64
    return h
end

function XxHash64:final()
    local h = self:value()
    -- Big-endian 8-byte digest (canonical xxhsum representation).
    return string.char(
        (h >> 56) & 0xFF, (h >> 48) & 0xFF,
        (h >> 40) & 0xFF, (h >> 32) & 0xFF,
        (h >> 24) & 0xFF, (h >> 16) & 0xFF,
        (h >>  8) & 0xFF,  h        & 0xFF)
end

function XxHash64:final_hex() return to_hex(self:final()) end

XxHash64.digest    = XxHash64.final
XxHash64.hexdigest = XxHash64.final_hex

function XxHash64:reset()
    self._total = 0
    self._buf   = ""
    self._v     = nil
    return self
end

local function xxhash64_new(seed)
    return setmetatable({
        _seed  = seed or 0,
        _total = 0,
        _buf   = "",
        _v     = nil,
    }, XxHash64)
end

-- ===== BLAKE3 (full algorithm, including chunk tree) ===================
-- Reference: https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf

local BLAKE3_OUT_LEN     = 32
local BLAKE3_BLOCK_LEN   = 64
local BLAKE3_CHUNK_LEN   = 1024

local CHUNK_START         = 1
local CHUNK_END           = 2
local PARENT              = 4
local ROOT                = 8
-- Other domain flags (KEYED_HASH/DERIVE_KEY_*) not used here; we hash.

local IV = {
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
}

local MSG_PERMUTATION = {
    3, 1, 6, 5, 11, 10, 14, 8, 16, 7, 13, 4, 9, 15, 12, 2,
    -- Lua is 1-indexed; we'll translate when applying.
}

local MASK32 = 0xFFFFFFFF

local function rotr32(x, n)
    x = x & MASK32
    return ((x >> n) | (x << (32 - n))) & MASK32
end

local function g(state, a, b, c, d, mx, my)
    state[a] = (state[a] + state[b] + mx) & MASK32
    state[d] = rotr32(state[d] ~ state[a], 16)
    state[c] = (state[c] + state[d]) & MASK32
    state[b] = rotr32(state[b] ~ state[c], 12)
    state[a] = (state[a] + state[b] + my) & MASK32
    state[d] = rotr32(state[d] ~ state[a], 8)
    state[c] = (state[c] + state[d]) & MASK32
    state[b] = rotr32(state[b] ~ state[c], 7)
end

local function round_fn(state, m)
    -- columns
    g(state, 1, 5,  9, 13, m[1],  m[2])
    g(state, 2, 6, 10, 14, m[3],  m[4])
    g(state, 3, 7, 11, 15, m[5],  m[6])
    g(state, 4, 8, 12, 16, m[7],  m[8])
    -- diagonals
    g(state, 1, 6, 11, 16, m[9],  m[10])
    g(state, 2, 7, 12, 13, m[11], m[12])
    g(state, 3, 8,  9, 14, m[13], m[14])
    g(state, 4, 5, 10, 15, m[15], m[16])
end

local function permute(m)
    local out = {}
    for i = 1, 16 do out[i] = m[MSG_PERMUTATION[i]] end
    return out
end

-- compress_in_place: returns a 16-word state vector.
local function compress(cv, block_words, counter, block_len, flags)
    local counter_lo = counter & MASK32
    local counter_hi = (counter >> 32) & MASK32
    local state = {
        cv[1], cv[2], cv[3], cv[4],
        cv[5], cv[6], cv[7], cv[8],
        IV[1], IV[2], IV[3], IV[4],
        counter_lo, counter_hi, block_len, flags,
    }
    local m = block_words
    for _ = 1, 6 do
        round_fn(state, m)
        m = permute(m)
    end
    round_fn(state, m)
    -- Final XOR-fold and CV-fold
    for i = 1, 8 do
        state[i]     = state[i]     ~ state[i + 8]
        state[i + 8] = state[i + 8] ~ cv[i]
    end
    return state
end

local function words_from_block(block, off)
    -- Read 16 little-endian u32s starting at off (1-based).
    local w = {}
    for i = 0, 15 do
        local p = off + i * 4
        local b1, b2, b3, b4 = block:byte(p, p + 3)
        w[i + 1] = b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
    end
    return w
end

local function chaining_value(state)
    return { state[1], state[2], state[3], state[4],
             state[5], state[6], state[7], state[8] }
end

-- Chunk state: incremental hashing of up to BLAKE3_CHUNK_LEN bytes.
local function chunk_new(key, chunk_counter, flags)
    return {
        cv = { key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8] },
        chunk_counter = chunk_counter,
        block        = "",     -- pending block bytes (< BLAKE3_BLOCK_LEN)
        blocks_compressed = 0,
        flags        = flags,
    }
end

local function chunk_len(c)
    return c.blocks_compressed * BLAKE3_BLOCK_LEN + #c.block
end

local function chunk_start_flag(c)
    return (c.blocks_compressed == 0) and CHUNK_START or 0
end

local function chunk_update(c, s)
    -- Greedily compress full 64-byte blocks. Defer the last block so we know
    -- which one needs CHUNK_END when the chunk closes.
    local data = c.block .. s
    local pos, len = 1, #data
    while len - pos + 1 > BLAKE3_BLOCK_LEN do
        local words = words_from_block(data, pos)
        local state = compress(c.cv, words, c.chunk_counter,
                               BLAKE3_BLOCK_LEN,
                               c.flags | chunk_start_flag(c))
        c.cv = chaining_value(state)
        c.blocks_compressed = c.blocks_compressed + 1
        pos = pos + BLAKE3_BLOCK_LEN
    end
    c.block = data:sub(pos)
end

local function chunk_output(c)
    -- Returns the "Output" for the chunk: cv, block-words, counter, len, flags.
    local block = c.block
    local block_len = #block
    -- Pad block with zeros to a full 64 bytes.
    if block_len < BLAKE3_BLOCK_LEN then
        block = block .. string.rep("\0", BLAKE3_BLOCK_LEN - block_len)
    end
    local words = words_from_block(block, 1)
    return {
        input_cv      = c.cv,
        block_words   = words,
        counter       = c.chunk_counter,
        block_len     = block_len,
        flags         = c.flags | chunk_start_flag(c) | CHUNK_END,
    }
end

local function parent_output(left_cv, right_cv, key, flags)
    -- Concatenate left || right into 16 words and compress with PARENT flag.
    local words = {}
    for i = 1, 8 do words[i] = left_cv[i] end
    for i = 1, 8 do words[i + 8] = right_cv[i] end
    return {
        input_cv      = { key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8] },
        block_words   = words,
        counter       = 0,
        block_len     = BLAKE3_BLOCK_LEN,
        flags         = flags | PARENT,
    }
end

local function output_chaining_value(o)
    local state = compress(o.input_cv, o.block_words, o.counter, o.block_len, o.flags)
    return chaining_value(state)
end

local function output_root_bytes(o, out_len)
    -- Stream root output blocks until we have out_len bytes.
    local out = {}
    local total = 0
    local block_idx = 0
    while total < out_len do
        local state = compress(o.input_cv, o.block_words,
                               block_idx, o.block_len, o.flags | ROOT)
        -- The 16-word state is the next 64 bytes of output (little-endian).
        for i = 1, 16 do
            if total >= out_len then break end
            local w = state[i]
            for shift = 0, 24, 8 do
                if total >= out_len then break end
                out[#out + 1] = string.char((w >> shift) & 0xFF)
                total = total + 1
            end
        end
        block_idx = block_idx + 1
    end
    return table.concat(out)
end

local Blake3 = {}
Blake3.__index = Blake3

function Blake3:update(s)
    if type(s) ~= "string" then error("hash:update expects string") end
    local pos, len = 1, #s
    while pos <= len do
        if chunk_len(self._chunk) == BLAKE3_CHUNK_LEN then
            -- Close current chunk -> push its CV onto the merge stack.
            local cv = output_chaining_value(chunk_output(self._chunk))
            local total = self._chunk.chunk_counter + 1
            -- "Add chunk" merging: while the lowest set bit of total is 0...
            -- actually: while there are two CVs that need merging.
            local stack = self._cv_stack
            local n = #stack
            local merge_count = 0
            -- Number of trailing zero bits in `total` tells us how many merges.
            local t = total
            while (t & 1) == 0 do
                merge_count = merge_count + 1
                t = t >> 1
            end
            for _ = 1, merge_count do
                local right = cv
                local left  = stack[n]
                stack[n] = nil; n = n - 1
                cv = output_chaining_value(parent_output(left, right, self._key, self._flags))
            end
            stack[n + 1] = cv
            self._cv_stack = stack
            -- Start the next chunk.
            self._chunk = chunk_new(self._key, total, self._flags)
        end
        local space = BLAKE3_CHUNK_LEN - chunk_len(self._chunk)
        local take = math.min(space, len - pos + 1)
        chunk_update(self._chunk, s:sub(pos, pos + take - 1))
        pos = pos + take
    end
    return self
end

function Blake3:_finalize_output()
    -- Walk the CV stack right-to-left, folding parents into the in-flight chunk's
    -- output, until a single root output remains.
    local o = chunk_output(self._chunk)
    local stack = self._cv_stack
    local n = #stack
    if n == 0 then
        return o
    end
    -- The current chunk's CV becomes the right child of every merge.
    local cv = output_chaining_value(o)
    -- Last merge becomes the actual ROOT output (don't reduce to a CV).
    for i = n, 2, -1 do
        local left = stack[i]
        cv = output_chaining_value(parent_output(left, cv, self._key, self._flags))
    end
    return parent_output(stack[1], cv, self._key, self._flags)
end

function Blake3:final(out_len)
    out_len = out_len or BLAKE3_OUT_LEN
    local o = self:_finalize_output()
    return output_root_bytes(o, out_len)
end

function Blake3:final_hex(out_len) return to_hex(self:final(out_len)) end

Blake3.digest    = Blake3.final
Blake3.hexdigest = Blake3.final_hex

function Blake3:reset()
    self._chunk    = chunk_new(self._key, 0, self._flags)
    self._cv_stack = {}
    return self
end

local function blake3_new()
    local key = { IV[1], IV[2], IV[3], IV[4], IV[5], IV[6], IV[7], IV[8] }
    return setmetatable({
        _key       = key,
        _flags     = 0,
        _chunk     = chunk_new(key, 0, 0),
        _cv_stack  = {},
    }, Blake3)
end

-- ===== xxHash32 (XXH32, official spec) =================================

local XXH32_P1 = 0x9E3779B1
local XXH32_P2 = 0x85EBCA77
local XXH32_P3 = 0xC2B2AE3D
local XXH32_P4 = 0x27D4EB2F
local XXH32_P5 = 0x165667B1

local function rotl32(x, r)
    x = x & MASK32
    return ((x << r) | (x >> (32 - r))) & MASK32
end

local function xxh32_round(acc, lane)
    acc = (acc + (lane * XXH32_P2)) & MASK32
    acc = rotl32(acc, 13)
    return (acc * XXH32_P1) & MASK32
end

local XxHash32 = {}
XxHash32.__index = XxHash32

function XxHash32:update(s)
    if type(s) ~= "string" then error("hash:update expects string") end
    self._total = self._total + #s
    if self._buf ~= "" then
        s = self._buf .. s
        self._buf = ""
    end
    local pos, len = 1, #s
    if self._v == nil and len >= 16 then
        self._v = {
            (self._seed + XXH32_P1 + XXH32_P2) & MASK32,
            (self._seed + XXH32_P2)             & MASK32,
             self._seed                         & MASK32,
            (self._seed - XXH32_P1)             & MASK32,
        }
    end
    while pos + 15 <= len do
        local v = self._v
        v[1] = xxh32_round(v[1], read_u32_le(s, pos))
        v[2] = xxh32_round(v[2], read_u32_le(s, pos +  4))
        v[3] = xxh32_round(v[3], read_u32_le(s, pos +  8))
        v[4] = xxh32_round(v[4], read_u32_le(s, pos + 12))
        pos = pos + 16
    end
    if pos <= len then self._buf = s:sub(pos) end
    return self
end

function XxHash32:value()
    local h
    if self._v ~= nil then
        local v = self._v
        h = (rotl32(v[1], 1) + rotl32(v[2], 7) + rotl32(v[3], 12) + rotl32(v[4], 18)) & MASK32
    else
        h = (self._seed + XXH32_P5) & MASK32
    end
    h = (h + self._total) & MASK32
    local rem = self._buf
    local i, n = 1, #rem
    while i + 3 <= n do
        h = (h + ((read_u32_le(rem, i) * XXH32_P3) & MASK32)) & MASK32
        h = (rotl32(h, 17) * XXH32_P4) & MASK32
        i = i + 4
    end
    while i <= n do
        h = (h + ((rem:byte(i) * XXH32_P5) & MASK32)) & MASK32
        h = (rotl32(h, 11) * XXH32_P1) & MASK32
        i = i + 1
    end
    h = (h ~ (h >> 15)) & MASK32
    h = (h * XXH32_P2)  & MASK32
    h = (h ~ (h >> 13)) & MASK32
    h = (h * XXH32_P3)  & MASK32
    h = (h ~ (h >> 16)) & MASK32
    return h
end

function XxHash32:final()
    local h = self:value()
    return string.char((h >> 24) & 0xFF, (h >> 16) & 0xFF,
                       (h >>  8) & 0xFF,  h        & 0xFF)
end

function XxHash32:final_hex() return to_hex(self:final()) end
XxHash32.digest    = XxHash32.final
XxHash32.hexdigest = XxHash32.final_hex

function XxHash32:reset()
    self._total = 0
    self._buf   = ""
    self._v     = nil
    return self
end

local function xxhash32_new(seed)
    return setmetatable({
        _seed  = (seed or 0) & MASK32,
        _total = 0,
        _buf   = "",
        _v     = nil,
    }, XxHash32)
end

-- ===== Dispatch ========================================================

local CNG_ALGOS = {
    md5 = true, sha1 = true, sha256 = true, sha384 = true, sha512 = true,
    sha3_256 = true, sha3_384 = true, sha3_512 = true,
}

function M.new(algo)
    if CNG_ALGOS[algo] then
        -- SHA-3 needs Win10 1903+; refuse rather than ship a half-baked
        -- pure-Lua Keccak that's only there as a "fallback".
        if (algo == "sha3_256" or algo == "sha3_384" or algo == "sha3_512")
           and not cng_has(algo) then
            error("hash: SHA-3 not available -- requires Windows 10 1903 or newer")
        end
        return cng_new(algo)
    end
    if algo == "crc32"     then return crc32_new()    end
    if algo == "xxhash32"  then return xxhash32_new() end
    if algo == "xxhash64"  then return xxhash64_new() end
    if algo == "blake3"    then return blake3_new()   end
    error("hash.new: unknown algorithm '" .. tostring(algo) .. "'")
end

-- Per the task spec, the bare `hash.sha256(s)` form returns the lowercase hex
-- digest (the JSON/REST-friendly form). The `_raw` variant returns the binary
-- digest. `_hex` is kept as an explicit-intent alias for the hex form.
local function make_oneshot(algo)
    M[algo]            = function(s, ...) return to_hex(M.new(algo):update(s):final(...)) end
    M[algo .. "_raw"]  = function(s, ...) return M.new(algo):update(s):final(...) end
    M[algo .. "_hex"]  = M[algo]
end

for algo in pairs(CNG_ALGOS) do make_oneshot(algo) end
make_oneshot("xxhash32")
make_oneshot("xxhash64")
make_oneshot("blake3")
make_oneshot("crc32")

-- CRC32 has a numeric variant that is occasionally useful.
M.crc32_value    = function(s) return crc32_new():update(s):value() end
M.xxhash32_value = function(s, seed) return xxhash32_new(seed):update(s):value() end
M.xxhash64_value = function(s, seed) return xxhash64_new(seed):update(s):value() end

-- ===== File streaming ==================================================
-- 64 KiB chunks balance syscall overhead with peak RSS.

local FILE_CHUNK = 65536

local function file_stream(algo, path, chunk_size)
    local f, err = io.open(path, "rb")
    if not f then error("hash.file: " .. tostring(err)) end
    local ctx = M.new(algo)
    chunk_size = chunk_size or FILE_CHUNK
    while true do
        local chunk = f:read(chunk_size)
        if chunk == nil or #chunk == 0 then break end
        ctx:update(chunk)
    end
    f:close()
    return ctx
end

function M.file(algo, path, chunk_size)
    return file_stream(algo, path, chunk_size):hexdigest()
end

function M.file_raw(algo, path, chunk_size)
    return file_stream(algo, path, chunk_size):digest()
end

return M
