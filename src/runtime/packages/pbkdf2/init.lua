-- pbkdf2 -- password-based key derivation.
--
-- Public surface:
--   pbkdf2(password, salt, iterations, keylen, algo?) -> bytes
--     RFC 2898 PBKDF2. PRF defaults to "sha256". iterations >= 1.
--   pbkdf2.derive(...)        -- alias for the callable form
--   pbkdf2.derive_hex(...)    -> lowercase hex of the derived key
--   pbkdf2.scrypt(password, salt, n, r, p, dklen) -> bytes
--     RFC 7914 scrypt. n must be a power of two. Pure Lua.
--   pbkdf2.argon2id(password, salt, t_cost, m_cost_kib, parallelism, dklen,
--                    secret?, ad?) -> bytes
--     Argon2id from RFC 9106. Pure Lua with a self-contained BLAKE2b.
--     NOTE: pure-Lua Argon2 is *extremely* slow (multi-second per call at
--     RFC-recommended cost params) -- meant for parity, not bulk hashing.
--
-- The PBKDF2 RFC 2898 path also tries BCryptDeriveKeyPBKDF2 when the PRF is
-- one of the BCrypt-native SHA family, falling back to pure Lua otherwise.

require "windows"
local BC   = require "windows.bcrypt"
local hash = require "hash"
local hmac = require "hmac"

local SUPPORTED = { sha1 = true, sha256 = true, sha384 = true, sha512 = true }

local function xor_bytes(a, b)
    -- a and b are equal-length byte strings.
    local n = #a
    local out = {}
    for i = 1, n do
        out[i] = string.char(a:byte(i) ~ b:byte(i))
    end
    return table.concat(out)
end

local function int_be(i)
    -- 32-bit big-endian encoding for the block index.
    return string.char(
        (i >> 24) & 0xFF,
        (i >> 16) & 0xFF,
        (i >>  8) & 0xFF,
         i        & 0xFF)
end

local BC_ALG_NAME = {
    sha1   = BC.SHA1_ALGORITHM,
    sha256 = BC.SHA256_ALGORITHM,
    sha384 = BC.SHA384_ALGORITHM,
    sha512 = BC.SHA512_ALGORITHM,
}

-- BCryptDeriveKeyPBKDF2 needs its own algorithm handle (BCRYPT_ALG_HANDLE_HMAC_FLAG).
local _bc_hmac_alg = {}
local function open_hmac_alg(algo)
    local cached = _bc_hmac_alg[algo]
    if cached ~= nil then return cached end
    local h = ffi.new("PVOID[1]")
    local status = ffi.C.BCryptOpenAlgorithmProvider(h, BC_ALG_NAME[algo], nil,
                                                    BC.BCRYPT_ALG_HANDLE_HMAC_FLAG)
    if status ~= 0 then return nil end
    _bc_hmac_alg[algo] = h[0]
    return h[0]
end

local function bcrypt_pbkdf2(password, salt, iterations, keylen, algo)
    local alg = open_hmac_alg(algo)
    if alg == nil then return nil end
    local pw_buf = ffi.new("unsigned char[?]", math.max(1, #password))
    if #password > 0 then ffi.copy(pw_buf, password, #password) end
    local salt_buf = ffi.new("unsigned char[?]", math.max(1, #salt))
    if #salt > 0 then ffi.copy(salt_buf, salt, #salt) end
    local out = ffi.new("unsigned char[?]", keylen)
    local status = ffi.C.BCryptDeriveKeyPBKDF2(alg,
        pw_buf, #password,
        salt_buf, #salt,
        iterations,
        out, keylen, 0)
    if status ~= 0 then return nil end
    return ffi.string(out, keylen)
end

local function derive(password, salt, iterations, keylen, algo)
    algo = algo or "sha256"
    if not SUPPORTED[algo] then
        error("pbkdf2: unsupported PRF '" .. tostring(algo) .. "'")
    end
    if type(password) ~= "string" then error("pbkdf2: password must be string") end
    if type(salt)     ~= "string" then error("pbkdf2: salt must be string")     end
    if type(iterations) ~= "number" or iterations < 1 or iterations ~= math.floor(iterations) then
        error("pbkdf2: iterations must be a positive integer")
    end
    if type(keylen) ~= "number" or keylen < 1 then
        error("pbkdf2: keylen must be a positive integer")
    end

    -- Prefer the native PBKDF2 -- it's an order of magnitude faster than the
    -- HMAC-in-Lua reference loop. Fall back transparently on failure.
    local fast = bcrypt_pbkdf2(password, salt, iterations, keylen, algo)
    if fast ~= nil then return fast end

    local hlen = hash.digest_size(algo)
    local blocks = math.ceil(keylen / hlen)
    if blocks > 0xFFFFFFFF then
        error("pbkdf2: derived key too long")
    end

    local out = {}
    for i = 1, blocks do
        -- U_1 = PRF(P, S || INT(i))
        local u = hmac.new(algo, password):update(salt):update(int_be(i)):final()
        local t = u
        for _ = 2, iterations do
            u = hmac.new(algo, password):update(u):final()
            t = xor_bytes(t, u)
        end
        out[i] = t
    end
    local dk = table.concat(out)
    return dk:sub(1, keylen)
end

-- ===== scrypt (RFC 7914, pure Lua) =====================================
-- Compatible with Colin Percival's reference implementation. Cost params:
--   N: CPU/memory cost (power of two, > 1)
--   r: block size factor (1..)
--   p: parallelism (1..)
-- Memory footprint is roughly 128 * N * r bytes.

local MASK32 = 0xFFFFFFFF

local function rotl32(x, n)
    x = x & MASK32
    return ((x << n) | (x >> (32 - n))) & MASK32
end

local function read_u32_le(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
end

local function pack_u32_le(v)
    return string.char(v & 0xFF, (v >> 8) & 0xFF,
                       (v >> 16) & 0xFF, (v >> 24) & 0xFF)
end

-- Salsa20/8 core: 64-byte in -> 64-byte out.
local function salsa20_8(B)
    local x = {}
    for i = 1, 16 do x[i] = read_u32_le(B, (i - 1) * 4 + 1) end
    local s = { x[1], x[2], x[3], x[4], x[5], x[6], x[7], x[8],
                x[9], x[10], x[11], x[12], x[13], x[14], x[15], x[16] }
    for _ = 1, 4 do
        -- columns
        s[5]  = s[5]  ~ rotl32((s[1]  + s[13]) & MASK32,  7)
        s[9]  = s[9]  ~ rotl32((s[5]  + s[1])  & MASK32,  9)
        s[13] = s[13] ~ rotl32((s[9]  + s[5])  & MASK32, 13)
        s[1]  = s[1]  ~ rotl32((s[13] + s[9])  & MASK32, 18)
        s[10] = s[10] ~ rotl32((s[6]  + s[2])  & MASK32,  7)
        s[14] = s[14] ~ rotl32((s[10] + s[6])  & MASK32,  9)
        s[2]  = s[2]  ~ rotl32((s[14] + s[10]) & MASK32, 13)
        s[6]  = s[6]  ~ rotl32((s[2]  + s[14]) & MASK32, 18)
        s[15] = s[15] ~ rotl32((s[11] + s[7])  & MASK32,  7)
        s[3]  = s[3]  ~ rotl32((s[15] + s[11]) & MASK32,  9)
        s[7]  = s[7]  ~ rotl32((s[3]  + s[15]) & MASK32, 13)
        s[11] = s[11] ~ rotl32((s[7]  + s[3])  & MASK32, 18)
        s[4]  = s[4]  ~ rotl32((s[16] + s[12]) & MASK32,  7)
        s[8]  = s[8]  ~ rotl32((s[4]  + s[16]) & MASK32,  9)
        s[12] = s[12] ~ rotl32((s[8]  + s[4])  & MASK32, 13)
        s[16] = s[16] ~ rotl32((s[12] + s[8])  & MASK32, 18)
        -- rows
        s[2]  = s[2]  ~ rotl32((s[1]  + s[4])  & MASK32,  7)
        s[3]  = s[3]  ~ rotl32((s[2]  + s[1])  & MASK32,  9)
        s[4]  = s[4]  ~ rotl32((s[3]  + s[2])  & MASK32, 13)
        s[1]  = s[1]  ~ rotl32((s[4]  + s[3])  & MASK32, 18)
        s[7]  = s[7]  ~ rotl32((s[6]  + s[5])  & MASK32,  7)
        s[8]  = s[8]  ~ rotl32((s[7]  + s[6])  & MASK32,  9)
        s[5]  = s[5]  ~ rotl32((s[8]  + s[7])  & MASK32, 13)
        s[6]  = s[6]  ~ rotl32((s[5]  + s[8])  & MASK32, 18)
        s[12] = s[12] ~ rotl32((s[11] + s[10]) & MASK32,  7)
        s[9]  = s[9]  ~ rotl32((s[12] + s[11]) & MASK32,  9)
        s[10] = s[10] ~ rotl32((s[9]  + s[12]) & MASK32, 13)
        s[11] = s[11] ~ rotl32((s[10] + s[9])  & MASK32, 18)
        s[13] = s[13] ~ rotl32((s[16] + s[15]) & MASK32,  7)
        s[14] = s[14] ~ rotl32((s[13] + s[16]) & MASK32,  9)
        s[15] = s[15] ~ rotl32((s[14] + s[13]) & MASK32, 13)
        s[16] = s[16] ~ rotl32((s[15] + s[14]) & MASK32, 18)
    end
    local out = {}
    for i = 1, 16 do
        out[i] = pack_u32_le((s[i] + x[i]) & MASK32)
    end
    return table.concat(out)
end

local function xor_strings(a, b)
    local n = #a
    local out = {}
    for i = 1, n do out[i] = string.char(a:byte(i) ~ b:byte(i)) end
    return table.concat(out)
end

-- BlockMix from RFC 7914 section 4.
local function block_mix(B, r)
    -- B is a string of 128*r bytes (2r 64-byte blocks).
    local X = B:sub(-64)
    local Y = {}
    for i = 0, 2 * r - 1 do
        local Bi = B:sub(i * 64 + 1, (i + 1) * 64)
        X = salsa20_8(xor_strings(X, Bi))
        Y[i + 1] = X
    end
    local out = {}
    for i = 0, r - 1 do
        out[i + 1]     = Y[2 * i + 1]
        out[i + r + 1] = Y[2 * i + 2]
    end
    return table.concat(out)
end

local function integerify_mod(B, r, N)
    -- Take the first 8 bytes of the last 64-byte block as little-endian u64,
    -- mod N. Since N is a power of two we can just mask.
    local off = (2 * r - 1) * 64 + 1
    local lo = read_u32_le(B, off)
    -- Top 32 bits are part of the u64 but for power-of-two N <= 2^32 we only
    -- need the low half.
    return lo & (N - 1)
end

local function smix(B, r, N)
    local V = {}
    local X = B
    for i = 1, N do
        V[i] = X
        X = block_mix(X, r)
    end
    for _ = 1, N do
        local j = integerify_mod(X, r, N)
        X = block_mix(xor_strings(X, V[j + 1]), r)
    end
    return X
end

local function scrypt(password, salt, N, r, p, dklen)
    if type(N) ~= "number" or N < 2 then error("scrypt: N must be >= 2") end
    if (N & (N - 1)) ~= 0 then error("scrypt: N must be a power of two") end
    if type(r) ~= "number" or r < 1 then error("scrypt: r must be >= 1") end
    if type(p) ~= "number" or p < 1 then error("scrypt: p must be >= 1") end
    if type(dklen) ~= "number" or dklen < 1 then error("scrypt: dklen must be >= 1") end
    -- B = PBKDF2-HMAC-SHA256(password, salt, 1, p * 128 * r)
    local B = derive(password, salt, 1, p * 128 * r, "sha256")
    local mixed = {}
    for i = 0, p - 1 do
        local Bi = B:sub(i * 128 * r + 1, (i + 1) * 128 * r)
        mixed[i + 1] = smix(Bi, r, N)
    end
    local B_prime = table.concat(mixed)
    return derive(password, B_prime, 1, dklen, "sha256")
end

-- ===== Argon2id (RFC 9106, pure Lua, BLAKE2b-backed) ===================
-- Includes a self-contained BLAKE2b so we don't pull in another package.
-- Argon2id alternates Argon2i (data-independent) and Argon2d (data-dependent)
-- addressing: pass 0 / first half of pass 1 use Argon2i, the rest Argon2d.

local MASK64 = 0xFFFFFFFFFFFFFFFF

local function rotr64(x, n)
    return ((x >> n) | (x << (64 - n))) & MASK64
end

local function read_u64_le(s, i)
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(i, i + 7)
    return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
        | (b5 << 32) | (b6 << 40) | (b7 << 48) | (b8 << 56)
end

local function pack_u64_le(v)
    return string.char(
        v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF,
        (v >> 32) & 0xFF, (v >> 40) & 0xFF, (v >> 48) & 0xFF, (v >> 56) & 0xFF)
end

local BLAKE2B_IV = {
    0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
    0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179,
}

local BLAKE2B_SIGMA = {
    { 1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16 },
    { 15, 11,  5,  9, 10, 16, 14,  7,  2, 13,  1,  3, 12,  8,  6,  4 },
    { 12,  9, 13,  1,  6,  3, 16, 14, 11, 15,  4,  7,  8,  2, 10,  5 },
    {  8, 10,  4,  2, 14, 13, 12, 15,  3,  7,  6, 11,  5,  1, 16,  9 },
    { 10,  1,  6,  8,  3,  5, 11, 16, 15,  2, 12, 13,  7,  9,  4, 14 },
    {  3, 13,  7, 11,  1, 12,  9,  4,  5, 14,  8,  6, 16, 15,  2, 10 },
    { 13,  6,  2, 16, 15, 14,  5, 11,  1,  8,  7,  4, 10,  3,  9, 12 },
    { 14, 12,  8, 15, 13,  2,  4, 10,  6,  1, 16,  5,  9,  7,  3, 11 },
    {  7, 16, 15, 10, 12,  4,  1,  9, 13,  3, 14,  8,  2,  5, 11,  6 },
    { 11,  3,  9,  5,  8,  7,  2,  6, 16, 12, 10, 15,  4, 13, 14,  1 },
    {  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16 },
    { 15, 11,  5,  9, 10, 16, 14,  7,  2, 13,  1,  3, 12,  8,  6,  4 },
}

local function b2b_g(v, a, b, c, d, x, y)
    v[a] = (v[a] + v[b] + x) & MASK64
    v[d] = rotr64(v[d] ~ v[a], 32)
    v[c] = (v[c] + v[d]) & MASK64
    v[b] = rotr64(v[b] ~ v[c], 24)
    v[a] = (v[a] + v[b] + y) & MASK64
    v[d] = rotr64(v[d] ~ v[a], 16)
    v[c] = (v[c] + v[d]) & MASK64
    v[b] = rotr64(v[b] ~ v[c], 63)
end

-- BLAKE2b compress; flags lo/hi go into t[1]/t[2] xor-paths.
local function blake2b_compress(h, block, t_lo, t_hi, last)
    local m = {}
    for i = 0, 15 do m[i + 1] = read_u64_le(block, i * 8 + 1) end
    local v = {}
    for i = 1, 8 do v[i] = h[i] end
    for i = 1, 8 do v[i + 8] = BLAKE2B_IV[i] end
    v[13] = v[13] ~ t_lo
    v[14] = v[14] ~ t_hi
    if last then v[15] = v[15] ~ MASK64 end
    for r = 1, 12 do
        local s = BLAKE2B_SIGMA[r]
        b2b_g(v, 1, 5,  9, 13, m[s[1]],  m[s[2]])
        b2b_g(v, 2, 6, 10, 14, m[s[3]],  m[s[4]])
        b2b_g(v, 3, 7, 11, 15, m[s[5]],  m[s[6]])
        b2b_g(v, 4, 8, 12, 16, m[s[7]],  m[s[8]])
        b2b_g(v, 1, 6, 11, 16, m[s[9]],  m[s[10]])
        b2b_g(v, 2, 7, 12, 13, m[s[11]], m[s[12]])
        b2b_g(v, 3, 8,  9, 14, m[s[13]], m[s[14]])
        b2b_g(v, 4, 5, 10, 15, m[s[15]], m[s[16]])
    end
    for i = 1, 8 do h[i] = (h[i] ~ v[i] ~ v[i + 8]) & MASK64 end
end

-- One-shot BLAKE2b with arbitrary output length 1..64 (Argon2 only needs <=64).
local function blake2b(data, out_len, key)
    out_len = out_len or 64
    key = key or ""
    if out_len < 1 or out_len > 64 then error("blake2b: out_len out of range") end
    local h = {
        BLAKE2B_IV[1] ~ (0x01010000 | (#key << 8) | out_len),
        BLAKE2B_IV[2], BLAKE2B_IV[3], BLAKE2B_IV[4],
        BLAKE2B_IV[5], BLAKE2B_IV[6], BLAKE2B_IV[7], BLAKE2B_IV[8],
    }
    local stream
    if #key > 0 then
        stream = key .. string.rep("\0", 128 - #key) .. data
    else
        stream = data
    end
    local n   = #stream
    local pos = 1
    local t   = 0
    while n - pos + 1 > 128 do
        t = t + 128
        blake2b_compress(h, stream:sub(pos, pos + 127), t, 0, false)
        pos = pos + 128
    end
    -- Last block.
    local last = stream:sub(pos)
    local last_len = #last
    if last_len < 128 then
        last = last .. string.rep("\0", 128 - last_len)
    end
    t = t + last_len
    blake2b_compress(h, last, t, 0, true)
    local out = {}
    for i = 1, 8 do out[i] = pack_u64_le(h[i]) end
    return table.concat(out):sub(1, out_len)
end

-- Variable-length Argon2 H' hash (RFC 9106 section 3.3).
local function h_prime(input, out_len)
    if out_len <= 64 then
        return blake2b(pack_u32_le(out_len) .. input, out_len)
    end
    local out = {}
    local V = blake2b(pack_u32_le(out_len) .. input, 64)
    out[#out + 1] = V:sub(1, 32)
    local remaining = out_len - 32
    while remaining > 64 do
        V = blake2b(V, 64)
        out[#out + 1] = V:sub(1, 32)
        remaining = remaining - 32
    end
    V = blake2b(V, remaining)
    out[#out + 1] = V
    return table.concat(out)
end

-- Argon2 block compression: GB function over 1024-byte blocks (128 u64 lanes).
local function blocks_from_string(s)
    local out = {}
    for i = 0, 127 do out[i + 1] = read_u64_le(s, i * 8 + 1) end
    return out
end

local function string_from_block(b)
    local out = {}
    for i = 1, 128 do out[i] = pack_u64_le(b[i]) end
    return table.concat(out)
end

local function gb(v, a, b, c, d)
    v[a] = (v[a] + v[b] + 2 * ((v[a] & 0xFFFFFFFF) * (v[b] & 0xFFFFFFFF))) & MASK64
    v[d] = rotr64(v[d] ~ v[a], 32)
    v[c] = (v[c] + v[d] + 2 * ((v[c] & 0xFFFFFFFF) * (v[d] & 0xFFFFFFFF))) & MASK64
    v[b] = rotr64(v[b] ~ v[c], 24)
    v[a] = (v[a] + v[b] + 2 * ((v[a] & 0xFFFFFFFF) * (v[b] & 0xFFFFFFFF))) & MASK64
    v[d] = rotr64(v[d] ~ v[a], 16)
    v[c] = (v[c] + v[d] + 2 * ((v[c] & 0xFFFFFFFF) * (v[d] & 0xFFFFFFFF))) & MASK64
    v[b] = rotr64(v[b] ~ v[c], 63)
end

local function p_perm(v, i1, i2, i3, i4, i5, i6, i7, i8,
                        i9, i10, i11, i12, i13, i14, i15, i16)
    gb(v, i1, i5,  i9, i13)
    gb(v, i2, i6, i10, i14)
    gb(v, i3, i7, i11, i15)
    gb(v, i4, i8, i12, i16)
    gb(v, i1, i6, i11, i16)
    gb(v, i2, i7, i12, i13)
    gb(v, i3, i8,  i9, i14)
    gb(v, i4, i5, i10, i15)
end

local function compress_g(X, Y)
    -- X, Y, R are 128-lane arrays. R = X xor Y. Apply P column- then row-wise.
    local R = {}
    for i = 1, 128 do R[i] = X[i] ~ Y[i] end
    local Z = {}
    for i = 1, 128 do Z[i] = R[i] end
    -- Column-wise rounds: 8 columns of 16 lanes each.
    for c = 0, 7 do
        local b = c * 16
        p_perm(Z, b+1, b+2, b+3, b+4, b+5, b+6, b+7, b+8,
                  b+9, b+10, b+11, b+12, b+13, b+14, b+15, b+16)
    end
    -- Row-wise rounds: 8 rows of 2 columns per row spread across 16 lanes.
    for r = 0, 7 do
        local b = r * 2
        p_perm(Z, b+1, b+2, b+17, b+18, b+33, b+34, b+49, b+50,
                  b+65, b+66, b+81, b+82, b+97, b+98, b+113, b+114)
    end
    local out = {}
    for i = 1, 128 do out[i] = (Z[i] ~ R[i]) & MASK64 end
    return out
end

local ARGON2ID_VERSION = 0x13
local ARGON2ID_TYPE    = 2

local function argon2id(password, salt, t_cost, m_cost, parallelism, dklen,
                         secret, ad)
    secret = secret or ""
    ad     = ad     or ""
    if type(password) ~= "string" then error("argon2id: password must be string") end
    if type(salt)     ~= "string" or #salt < 8 then
        error("argon2id: salt must be a string of at least 8 bytes")
    end
    if type(t_cost) ~= "number" or t_cost < 1 then
        error("argon2id: t_cost must be >= 1")
    end
    if type(parallelism) ~= "number" or parallelism < 1 then
        error("argon2id: parallelism must be >= 1")
    end
    if type(m_cost) ~= "number" or m_cost < 8 * parallelism then
        error("argon2id: m_cost must be >= 8 * parallelism (KiB)")
    end
    if type(dklen) ~= "number" or dklen < 4 then
        error("argon2id: dklen must be >= 4")
    end
    -- Memory block count m'; columns per lane q; columns per slice
    local m_prime = (m_cost // (4 * parallelism)) * (4 * parallelism)
    local lane_len = m_prime // parallelism
    local seg_len  = lane_len // 4

    -- H0 (pre-hash): hash of all parameters and inputs concatenated.
    local h0_input =
        pack_u32_le(parallelism) ..
        pack_u32_le(dklen) ..
        pack_u32_le(m_cost) ..
        pack_u32_le(t_cost) ..
        pack_u32_le(ARGON2ID_VERSION) ..
        pack_u32_le(ARGON2ID_TYPE) ..
        pack_u32_le(#password) .. password ..
        pack_u32_le(#salt)     .. salt ..
        pack_u32_le(#secret)   .. secret ..
        pack_u32_le(#ad)       .. ad
    local H0 = blake2b(h0_input, 64)

    -- Memory matrix B[lane][col]. Lanes stored as Lua tables of 1024-byte blocks.
    local B = {}
    for i = 0, parallelism - 1 do B[i] = {} end
    for i = 0, parallelism - 1 do
        B[i][0] = blocks_from_string(h_prime(H0 .. pack_u32_le(0) .. pack_u32_le(i), 1024))
        B[i][1] = blocks_from_string(h_prime(H0 .. pack_u32_le(1) .. pack_u32_le(i), 1024))
    end

    -- For each pass and segment, compute remaining columns.
    -- Single-lane fast path is the common case (Argon2id parallelism=1) and
    -- avoids the inter-lane index logic.
    for pass = 0, t_cost - 1 do
        for slice = 0, 3 do
            for lane = 0, parallelism - 1 do
                local start_col = (pass == 0 and slice == 0) and 2 or 0
                local seg_start = slice * seg_len
                for idx = start_col, seg_len - 1 do
                    local col = seg_start + idx
                    if col >= lane_len then break end
                    -- Argon2id: first half of the first pass uses Argon2i (data-independent),
                    -- everything else uses Argon2d (data-dependent).
                    local use_independent = (pass == 0) and (slice < 2)
                    local J1, J2
                    local prev_col = (col == 0) and (lane_len - 1) or (col - 1)
                    if use_independent then
                        -- Build address block using G(0, G(0, Z||...)) per RFC 9106 sec 3.4.
                        -- For simplicity we recompute per segment-block. (Slow but correct.)
                        local zeros = {}
                        for i = 1, 128 do zeros[i] = 0 end
                        local in_block = {}
                        for i = 1, 128 do in_block[i] = 0 end
                        in_block[1] = pass
                        in_block[2] = lane
                        in_block[3] = slice
                        in_block[4] = m_prime
                        in_block[5] = t_cost
                        in_block[6] = ARGON2ID_TYPE
                        in_block[7] = (idx // 128) + 1
                        local addr = compress_g(zeros, compress_g(zeros, in_block))
                        local pair = addr[(idx % 128) + 1]
                        J1 = pair & 0xFFFFFFFF
                        J2 = (pair >> 32) & 0xFFFFFFFF
                    else
                        local pair = B[lane][prev_col][1]
                        J1 = pair & 0xFFFFFFFF
                        J2 = (pair >> 32) & 0xFFFFFFFF
                    end
                    local ref_lane
                    if pass == 0 and slice == 0 then
                        ref_lane = lane
                    else
                        ref_lane = J2 % parallelism
                    end
                    -- Reference area size: all complete prior slices in ref_lane, plus
                    -- already-computed columns of the current slice if same lane.
                    local same = (ref_lane == lane)
                    local ref_area_size
                    if pass == 0 then
                        if slice == 0 then
                            ref_area_size = idx - 1
                        else
                            -- Cross-lane (different lane) refs may only see the
                            -- ref lane's FINISHED slices, never its current
                            -- (still-being-filled) slice -- so add 0, not idx.
                            -- The old `or idx` over-sized the window into the
                            -- uncomputed current slice -> nil ref block / crash
                            -- for parallelism >= 2 (RFC 9106 sec 3.4.1.2).
                            ref_area_size = slice * seg_len + (same and (idx - 1) or
                                                                (idx == 0 and -1 or 0))
                        end
                    else
                        ref_area_size = lane_len - seg_len + (same and (idx - 1) or
                                                                (idx == 0 and -1 or 0))
                    end
                    if ref_area_size < 0 then ref_area_size = 0 end
                    -- Non-uniform position selection over reference area.
                    local x = (J1 * J1) >> 32
                    local y = (ref_area_size * x) >> 32
                    local z = ref_area_size - 1 - y
                    local start_pos = (pass ~= 0 and slice ~= 3) and ((slice + 1) * seg_len) or 0
                    local ref_index = (start_pos + z) % lane_len
                    local ref_block = B[ref_lane][ref_index]
                    local prev_block = B[lane][prev_col]
                    if pass == 0 then
                        B[lane][col] = compress_g(prev_block, ref_block)
                    else
                        local nb = compress_g(prev_block, ref_block)
                        local prev = B[lane][col]
                        for i = 1, 128 do nb[i] = nb[i] ~ prev[i] end
                        B[lane][col] = nb
                    end
                end
            end
        end
    end
    -- Final block: xor the last column of each lane.
    local final = {}
    for i = 1, 128 do final[i] = 0 end
    for i = 0, parallelism - 1 do
        local last = B[i][lane_len - 1]
        for j = 1, 128 do final[j] = final[j] ~ last[j] end
    end
    return h_prime(string_from_block(final), dklen)
end

-- Allow both pbkdf2(...) and pbkdf2.derive(...).
local M = setmetatable({}, { __call = function(_, ...) return derive(...) end })
M.derive     = derive
M.derive_hex = function(...) return hash.to_hex(derive(...)) end
M.scrypt     = scrypt
M.scrypt_hex = function(...) return hash.to_hex(scrypt(...)) end
M.argon2id   = argon2id
M.argon2id_hex = function(...) return hash.to_hex(argon2id(...)) end

return M
