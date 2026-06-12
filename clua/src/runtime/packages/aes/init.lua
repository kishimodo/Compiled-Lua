-- aes -- AES symmetric crypto via Windows CNG (BCrypt).
--
-- Modes: "ecb", "cbc", "ctr", "gcm". Key length picks the AES variant:
-- 16 -> AES-128, 24 -> AES-192, 32 -> AES-256.
--
-- Public surface:
--   aes.encrypt(key, plaintext, opts)
--       opts = { mode="gcm"|"cbc"|"ctr"|"ecb", iv=..., aad=... }
--       -> ciphertext (and tag for GCM as second return)
--   aes.decrypt(key, ciphertext, opts)
--       opts as above, plus tag=... for GCM
--       -> plaintext
--   aes.encryptor(key, opts) / aes.decryptor(key, opts)
--       -> streaming object with :update(chunk) and :final()
--   aes.random_iv(size?)    -> bytes (default 16 for ECB/CBC, 12 for GCM, 16 for CTR)
--   aes.pad_pkcs7(s, bs?)   -> padded
--   aes.unpad_pkcs7(s, bs?) -> unpadded (errors on bad padding)
--
-- Legacy positional API is preserved:
--   aes.encrypt(mode, key, plaintext, iv?, aad?) and
--   aes.decrypt(mode, key, ciphertext, iv?, aad?, tag?).
--
-- ECB has no IV. CTR is implemented via an aes-ECB-keyed counter XOR'd
-- with plaintext (CNG has no native CTR mode); IV is the 16-byte initial
-- counter value (caller's responsibility to keep it unique per key).
-- GCM tag is 16 bytes; decrypt raises on tag mismatch.

require "windows"
local BC = require "windows.bcrypt"

local M = {}

local AES_BLOCK = 16
local GCM_TAG   = 16

-- ===== Algorithm provider cache ========================================

local _alg_handles = {}  -- chain mode -> opened algorithm provider

local function open_alg(chain_mode_w)
    local h = ffi.new("PVOID[1]")
    local status = ffi.C.BCryptOpenAlgorithmProvider(h, BC.AES_ALGORITHM, nil, 0)
    if status ~= 0 then
        error(string.format("aes: BCryptOpenAlgorithmProvider failed 0x%08X", status))
    end
    local alg = h[0]
    -- ChainingMode property is a UTF-16 string including its terminator.
    local mode_bytes = ffi.sizeof(chain_mode_w)
    status = ffi.C.BCryptSetProperty(alg, BC.PROP_CHAINING_MODE,
                                     ffi.cast("PVOID", chain_mode_w),
                                     mode_bytes, 0)
    if status ~= 0 then
        ffi.C.BCryptCloseAlgorithmProvider(alg, 0)
        error(string.format("aes: BCryptSetProperty ChainingMode failed 0x%08X", status))
    end
    return alg
end

local function get_alg_for(mode)
    -- CTR uses an ECB-keyed counter block. ECB/CBC/GCM map 1:1.
    local key
    if     mode == "ecb" or mode == "ctr" then key = "ecb"
    elseif mode == "cbc"                  then key = "cbc"
    elseif mode == "gcm"                  then key = "gcm"
    else error("aes: unsupported mode '" .. tostring(mode) .. "'") end
    local h = _alg_handles[key]
    if h ~= nil then return h end
    local mode_w
    if     key == "ecb" then mode_w = BC.CHAIN_MODE_ECB
    elseif key == "cbc" then mode_w = BC.CHAIN_MODE_CBC
    else                     mode_w = BC.CHAIN_MODE_GCM end
    h = open_alg(mode_w)
    _alg_handles[key] = h
    return h
end

-- ===== Key import ======================================================

local function import_key(alg, key)
    if not (#key == 16 or #key == 24 or #key == 32) then
        error("aes: key must be 16, 24 or 32 bytes (AES-128/192/256)")
    end
    -- BCryptGenerateSymmetricKey takes raw key bytes (pbSecret/cbSecret).
    -- BCRYPT_KEY_DATA_BLOB is the format for BCryptImportKey, not this API.
    local n = #key
    local key_buf = ffi.new("unsigned char[?]", n)
    ffi.copy(key_buf, key, n)
    local kh = ffi.new("PVOID[1]")
    local status = ffi.C.BCryptGenerateSymmetricKey(alg, kh, nil, 0, key_buf, n, 0)
    if status ~= 0 then
        error(string.format("aes: BCryptGenerateSymmetricKey failed 0x%08X", status))
    end
    return ffi.gc(kh[0], ffi.C.BCryptDestroyKey)
end

-- ===== PKCS#7 padding ==================================================

local function pad_pkcs7(s, bs)
    bs = bs or AES_BLOCK
    local pad = bs - (#s % bs)
    return s .. string.rep(string.char(pad), pad)
end
M.pad_pkcs7 = pad_pkcs7

local function unpad_pkcs7(s, bs)
    bs = bs or AES_BLOCK
    local n = #s
    if n == 0 or (n % bs) ~= 0 then error("aes: padded length is not a block multiple") end
    local pad = s:byte(n)
    if pad < 1 or pad > bs then error("aes: bad PKCS#7 padding byte") end
    for i = n - pad + 1, n do
        if s:byte(i) ~= pad then error("aes: bad PKCS#7 padding bytes") end
    end
    return s:sub(1, n - pad)
end
M.unpad_pkcs7 = unpad_pkcs7

-- ===== Random IV =======================================================

function M.random_iv(size)
    size = size or AES_BLOCK
    local buf = ffi.new("unsigned char[?]", size)
    local status = ffi.C.BCryptGenRandom(nil, buf, size, BC.USE_SYSTEM_PREFERRED_RNG)
    if status ~= 0 then
        error(string.format("aes: BCryptGenRandom failed 0x%08X", status))
    end
    return ffi.string(buf, size)
end

-- ===== ECB / CBC encrypt+decrypt =======================================

local function ecb_cbc_crypt(mode, key, data, iv, encrypt)
    local alg = get_alg_for(mode)
    local kh  = import_key(alg, key)
    local iv_buf, iv_len = nil, 0
    if mode == "cbc" then
        if type(iv) ~= "string" or #iv ~= AES_BLOCK then
            error("aes: CBC requires a 16-byte IV")
        end
        iv_buf = ffi.new("unsigned char[?]", AES_BLOCK)
        ffi.copy(iv_buf, iv, AES_BLOCK)
        iv_len = AES_BLOCK
    end
    -- Padding is handled by CNG's BCRYPT_BLOCK_PADDING flag in BOTH
    -- directions (it adds PKCS#7 on encrypt and strips it on decrypt).
    -- Do NOT also pad manually here -- doing both double-pads the input
    -- (a 32-byte plaintext became 64 bytes of ciphertext and decrypt
    -- returned 48), since the decrypt side only undoes CNG's one layer.
    -- The exported aes.pad_pkcs7/unpad_pkcs7 helpers remain for callers
    -- who want to pad by hand.
    local in_data
    if encrypt then
        in_data = data
    else
        if (#data % AES_BLOCK) ~= 0 then
            error("aes: ciphertext length is not a multiple of 16")
        end
        in_data = data
    end
    local in_buf = ffi.new("unsigned char[?]", #in_data)
    ffi.copy(in_buf, in_data, #in_data)
    -- Query output size
    local out_len = ffi.new("ULONG[1]")
    local op = encrypt and ffi.C.BCryptEncrypt or ffi.C.BCryptDecrypt
    local status = op(kh, in_buf, #in_data, nil,
                      iv_buf, iv_len,
                      nil, 0, out_len, BC.BLOCK_PADDING)
    if status ~= 0 then
        error(string.format("aes: size query failed 0x%08X", status))
    end
    -- Reset IV (CNG mutates iv buffer in CBC).
    if mode == "cbc" then ffi.copy(iv_buf, iv, AES_BLOCK) end
    local out_buf = ffi.new("unsigned char[?]", out_len[0])
    status = op(kh, in_buf, #in_data, nil,
                iv_buf, iv_len,
                out_buf, out_len[0], out_len, BC.BLOCK_PADDING)
    if status ~= 0 then
        error(string.format("aes: crypt op failed 0x%08X", status))
    end
    local out = ffi.string(out_buf, out_len[0])
    if not encrypt then
        -- BCrypt strips PKCS#7 for us when BLOCK_PADDING is set.
        return out
    end
    return out
end

-- ===== CTR (synthesized over ECB) =====================================
-- CNG has no native CTR, but it's simply XOR(plaintext, AES_ECB(K, counter++)).
-- The IV is interpreted as a 16-byte big-endian counter block.

local function ctr_crypt(key, data, iv)
    if type(iv) ~= "string" or #iv ~= AES_BLOCK then
        error("aes: CTR requires a 16-byte IV (initial counter block)")
    end
    local alg = get_alg_for("ecb")
    local kh  = import_key(alg, key)

    -- Build a counter buffer we can mutate.
    local counter = ffi.new("unsigned char[?]", AES_BLOCK)
    ffi.copy(counter, iv, AES_BLOCK)
    local stream = ffi.new("unsigned char[?]", AES_BLOCK)
    local stream_len = ffi.new("ULONG[1]")
    local out = {}
    local n = #data
    local pos = 0
    while pos < n do
        -- Encrypt one counter block.
        local status = ffi.C.BCryptEncrypt(kh, counter, AES_BLOCK, nil,
                                           nil, 0,
                                           stream, AES_BLOCK, stream_len, 0)
        if status ~= 0 then
            error(string.format("aes: CTR keystream gen failed 0x%08X", status))
        end
        local take = math.min(AES_BLOCK, n - pos)
        local chunk = {}
        for i = 1, take do
            chunk[i] = string.char(data:byte(pos + i) ~ stream[i - 1])
        end
        out[#out + 1] = table.concat(chunk)
        pos = pos + take
        -- Big-endian increment of the counter block.
        local idx = AES_BLOCK - 1
        while idx >= 0 do
            local v = (counter[idx] + 1) & 0xFF
            counter[idx] = v
            if v ~= 0 then break end
            idx = idx - 1
        end
    end
    return table.concat(out)
end

-- ===== GCM =============================================================

local function gcm_crypt(key, data, iv, aad, tag_in, encrypt)
    if type(iv) ~= "string" or #iv < 1 then
        error("aes: GCM requires a non-empty nonce (12 bytes recommended)")
    end
    local alg = get_alg_for("gcm")
    local kh  = import_key(alg, key)

    aad = aad or ""
    local nonce_buf = ffi.new("unsigned char[?]", #iv)
    ffi.copy(nonce_buf, iv, #iv)
    local aad_buf
    if #aad > 0 then
        aad_buf = ffi.new("unsigned char[?]", #aad)
        ffi.copy(aad_buf, aad, #aad)
    end

    local info = ffi.new("BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO")
    info.cbSize        = ffi.sizeof("BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO")
    info.dwInfoVersion = BC.BCRYPT_AUTH_MODE_INFO_VERSION
    info.pbNonce       = nonce_buf
    info.cbNonce       = #iv
    info.pbAuthData    = aad_buf or nil
    info.cbAuthData    = #aad

    -- For one-shot mode (no chaining), tag goes in the info blob.
    local tag_buf = ffi.new("unsigned char[?]", GCM_TAG)
    if not encrypt then
        if type(tag_in) ~= "string" or #tag_in ~= GCM_TAG then
            error("aes: GCM decrypt requires a 16-byte tag")
        end
        ffi.copy(tag_buf, tag_in, GCM_TAG)
    end
    info.pbTag = tag_buf
    info.cbTag = GCM_TAG

    local in_buf = ffi.new("unsigned char[?]", math.max(1, #data))
    if #data > 0 then ffi.copy(in_buf, data, #data) end

    local out_len = ffi.new("ULONG[1]")
    local op = encrypt and ffi.C.BCryptEncrypt or ffi.C.BCryptDecrypt
    local status = op(kh, in_buf, #data, info, nil, 0, nil, 0, out_len, 0)
    if status ~= 0 then
        error(string.format("aes: GCM size query failed 0x%08X", status))
    end
    local out_buf = ffi.new("unsigned char[?]", math.max(1, out_len[0]))
    status = op(kh, in_buf, #data, info, nil, 0,
                out_buf, out_len[0], out_len, 0)
    if status ~= 0 then
        -- 0xC000A002 = STATUS_AUTH_TAG_MISMATCH
        if (not encrypt) and ((status & 0xFFFFFFFF) == 0xC000A002) then
            error("aes: GCM authentication failed (tag mismatch)")
        end
        error(string.format("aes: GCM op failed 0x%08X", status))
    end
    local out = ffi.string(out_buf, out_len[0])
    if encrypt then
        return out, ffi.string(tag_buf, GCM_TAG)
    end
    return out
end

-- ===== Public dispatch =================================================

local MODES = { ecb = true, cbc = true, ctr = true, gcm = true }

local function do_encrypt(mode, key, plaintext, iv, aad)
    if type(plaintext) ~= "string" then error("aes.encrypt: plaintext must be string") end
    if mode == "ecb" then return ecb_cbc_crypt("ecb", key, plaintext, nil, true) end
    if mode == "cbc" then return ecb_cbc_crypt("cbc", key, plaintext, iv,  true) end
    if mode == "ctr" then return ctr_crypt(key, plaintext, iv) end
    if mode == "gcm" then return gcm_crypt(key, plaintext, iv, aad, nil, true) end
    error("aes.encrypt: unsupported mode '" .. tostring(mode) .. "'")
end

local function do_decrypt(mode, key, ciphertext, iv, aad, tag)
    if type(ciphertext) ~= "string" then error("aes.decrypt: ciphertext must be string") end
    if mode == "ecb" then return ecb_cbc_crypt("ecb", key, ciphertext, nil, false) end
    if mode == "cbc" then return ecb_cbc_crypt("cbc", key, ciphertext, iv,  false) end
    if mode == "ctr" then return ctr_crypt(key, ciphertext, iv) end
    if mode == "gcm" then return gcm_crypt(key, ciphertext, iv, aad, tag, false) end
    error("aes.decrypt: unsupported mode '" .. tostring(mode) .. "'")
end

-- Accept either the modern opts-table API or the legacy positional API.
-- The legacy form is detected by the first argument being a known mode string.
function M.encrypt(...)
    local a1, a2, a3, a4, a5 = ...
    if type(a1) == "string" and MODES[a1] then
        return do_encrypt(a1, a2, a3, a4, a5)
    end
    -- Modern: encrypt(key, plaintext, opts)
    local key, plaintext, opts = a1, a2, a3 or {}
    return do_encrypt(opts.mode or "gcm", key, plaintext, opts.iv, opts.aad)
end

function M.decrypt(...)
    local a1, a2, a3, a4, a5, a6 = ...
    if type(a1) == "string" and MODES[a1] then
        return do_decrypt(a1, a2, a3, a4, a5, a6)
    end
    local key, ciphertext, opts = a1, a2, a3 or {}
    return do_decrypt(opts.mode or "gcm", key, ciphertext, opts.iv, opts.aad, opts.tag)
end

-- ===== Streaming object (buffer-and-finalize) =========================
-- CNG one-shot semantics mean we can't truly stream block-by-block without
-- juggling chained BCRYPT_BLOCK_PADDING + IV state. The :update calls buffer
-- the chunks and :final runs the underlying mode in one shot. This matches
-- caller expectations (the "stream" is the convenience, not zero-copy I/O).

local Streamer = {}
Streamer.__index = Streamer

function Streamer:update(chunk)
    if type(chunk) ~= "string" then error("aes.stream:update expects a string chunk") end
    self._buf[#self._buf + 1] = chunk
    return self
end

function Streamer:final()
    local data = table.concat(self._buf)
    self._buf = {}
    if self._encrypt then
        local ct, tag = do_encrypt(self._mode, self._key, data, self._iv, self._aad)
        if self._mode == "gcm" then return ct, tag end
        return ct
    else
        return do_decrypt(self._mode, self._key, data, self._iv, self._aad, self._tag)
    end
end

local function new_stream(key, opts, encrypt)
    opts = opts or {}
    return setmetatable({
        _encrypt = encrypt,
        _mode    = opts.mode or "gcm",
        _key     = key,
        _iv      = opts.iv,
        _aad     = opts.aad,
        _tag     = opts.tag,
        _buf     = {},
    }, Streamer)
end

function M.encryptor(key, opts) return new_stream(key, opts, true)  end
function M.decryptor(key, opts) return new_stream(key, opts, false) end

return M
