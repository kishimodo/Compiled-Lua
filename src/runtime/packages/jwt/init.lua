-- jwt -- JSON Web Token (RFC 7519) sign/verify.
--
-- Algorithms:
--   HS256, HS384, HS512  -- HMAC with shared secret (string key)
--   RS256, RS384, RS512  -- RSA PKCS#1 v1.5; key = { kind="rsa", blob=<BCRYPT_RSAKEY_BLOB bytes> }
--   PS256, PS384, PS512  -- RSA-PSS (MGF1+salt=hashLen); key = { blob=<BCRYPT_RSAKEY_BLOB bytes> }
--   ES256, ES384, ES512  -- ECDSA P-256/P-384/P-521; key = { kind="ecdsa", curve="P-256", blob=... }
--
-- jwt.decode_unverified(token) -> { header, payload, signature } -- skips signature
-- check entirely. Useful for inspecting tokens whose key isn't on hand.
--
-- RSA/ECDSA keys are passed as BCrypt blobs because cross-platform PEM parsing
-- is a separate concern -- the x509 package exposes the bits for SubjectPublicKeyInfo.
--
-- Public surface:
--   jwt.encode(claims, key, algo)            -> token string
--   jwt.decode(token, key, algo, opts?)      -> claims | (nil, err)
--   jwt.verify(token, key, algo, opts?)      -> claims | (nil, err)  (alias)
--   jwt.b64url_encode(bytes) / b64url_decode(s)
--
-- opts (for decode):
--   leeway   -- seconds of clock skew tolerated for exp/nbf/iat (default 0)
--   now      -- override current time (seconds since epoch)
--   issuer   -- required 'iss' value
--   audience -- required 'aud' value (string or list)
--   subject  -- required 'sub' value
--   verify_exp / verify_nbf / verify_iat -- default true if claim present

local json = require "json"
local hmac = require "hmac"
require "windows"
local BC = require "windows.bcrypt"

local M = {}

-- ===== base64url =======================================================

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local _b64u_enc = {}
local _b64u_dec = {}
for i = 1, 64 do
    local c = B64:sub(i, i)
    _b64u_enc[i - 1] = c
    _b64u_dec[c:byte()] = i - 1
end
-- Also accept '+/' so we tolerate non-url-safe inputs.
_b64u_dec[string.byte("+")] = _b64u_dec[string.byte("-")]
_b64u_dec[string.byte("/")] = _b64u_dec[string.byte("_")]

local function b64url_encode(bytes)
    local len = #bytes
    local out, n = {}, 0
    local i = 1
    while i + 2 <= len do
        local b1, b2, b3 = bytes:byte(i, i + 2)
        local v = b1 * 65536 + b2 * 256 + b3
        n = n + 1; out[n] = _b64u_enc[(v >> 18) & 0x3F]
        n = n + 1; out[n] = _b64u_enc[(v >> 12) & 0x3F]
        n = n + 1; out[n] = _b64u_enc[(v >> 6) & 0x3F]
        n = n + 1; out[n] = _b64u_enc[v & 0x3F]
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local b1 = bytes:byte(i)
        local v = b1 * 65536
        n = n + 1; out[n] = _b64u_enc[(v >> 18) & 0x3F]
        n = n + 1; out[n] = _b64u_enc[(v >> 12) & 0x3F]
    elseif rem == 2 then
        local b1, b2 = bytes:byte(i, i + 1)
        local v = b1 * 65536 + b2 * 256
        n = n + 1; out[n] = _b64u_enc[(v >> 18) & 0x3F]
        n = n + 1; out[n] = _b64u_enc[(v >> 12) & 0x3F]
        n = n + 1; out[n] = _b64u_enc[(v >> 6) & 0x3F]
    end
    return table.concat(out)
end

local function b64url_decode(s)
    local len = #s
    local out, n = {}, 0
    local accum, bits = 0, 0
    for i = 1, len do
        local b = s:byte(i)
        if b == 61 then break end                -- '=' padding (we ignore it)
        if not (b == 32 or b == 9 or b == 10 or b == 13) then
            local v = _b64u_dec[b]
            if v == nil then
                error(string.format("jwt: invalid base64url character 0x%02X", b))
            end
            accum = (accum << 6) | v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                n = n + 1; out[n] = string.char((accum >> bits) & 0xFF)
                accum = accum & ((1 << bits) - 1)
            end
        end
    end
    return table.concat(out)
end

M.b64url_encode = b64url_encode
M.b64url_decode = b64url_decode

-- ===== Algorithm table =================================================

local HS = { HS256 = "sha256", HS384 = "sha384", HS512 = "sha512" }
local RS = { RS256 = "sha256", RS384 = "sha384", RS512 = "sha512" }
local PS = { PS256 = "sha256", PS384 = "sha384", PS512 = "sha512" }
local ES = { ES256 = "sha256", ES384 = "sha384", ES512 = "sha512" }

local PSS_SALT = { PS256 = 32, PS384 = 48, PS512 = 64 }
local PSS_ALGID = {
    PS256 = BC.SHA256_ALGORITHM,
    PS384 = BC.SHA384_ALGORITHM,
    PS512 = BC.SHA512_ALGORITHM,
}

local ES_INFO = {
    ES256 = { alg = BC.ECDSA_P256_ALGORITHM, sig_size = 64,  half = 32  },
    ES384 = { alg = BC.ECDSA_P384_ALGORITHM, sig_size = 96,  half = 48  },
    ES512 = { alg = BC.ECDSA_P521_ALGORITHM, sig_size = 132, half = 66  },
}

local RS_PKCS1 = {
    RS256 = BC.SHA256_ALGORITHM,
    RS384 = BC.SHA384_ALGORITHM,
    RS512 = BC.SHA512_ALGORITHM,
}

-- ===== Hash helper (raw bytes via the hash package) ===================
-- We don't reach into BCrypt directly for hashing -- the hash package already
-- maintains an algorithm-handle cache and gives us consistent error paths.

local hash = require "hash"

local function jwt_hash(hash_name, bytes)
    return hash.new(hash_name):update(bytes):final()
end

-- ===== RSA / ECDSA key import ==========================================

local function import_rsa_public(blob)
    -- Caller supplies BCRYPT_RSAPUBLIC_BLOB bytes (header + exponent + modulus).
    local h_alg = ffi.new("PVOID[1]")
    local s = ffi.C.BCryptOpenAlgorithmProvider(h_alg, BC.RSA_ALGORITHM, nil, 0)
    if s ~= 0 then error(string.format("jwt: open RSA alg failed 0x%08X", s)) end
    local alg = ffi.gc(h_alg[0], function(p) ffi.C.BCryptCloseAlgorithmProvider(p, 0) end)
    local blob_buf = ffi.new("unsigned char[?]", #blob)
    ffi.copy(blob_buf, blob, #blob)
    local kh = ffi.new("PVOID[1]")
    s = ffi.C.BCryptImportKeyPair(alg, nil, BC.BLOB_RSAPUBLIC, kh,
                                   blob_buf, #blob, 0)
    if s ~= 0 then error(string.format("jwt: RSA import failed 0x%08X", s)) end
    return ffi.gc(kh[0], ffi.C.BCryptDestroyKey), alg
end

local function import_ecdsa(blob, blob_type_w, alg_name_w)
    local h_alg = ffi.new("PVOID[1]")
    local s = ffi.C.BCryptOpenAlgorithmProvider(h_alg, alg_name_w, nil, 0)
    if s ~= 0 then error(string.format("jwt: open ECDSA alg failed 0x%08X", s)) end
    local alg = ffi.gc(h_alg[0], function(p) ffi.C.BCryptCloseAlgorithmProvider(p, 0) end)
    local blob_buf = ffi.new("unsigned char[?]", #blob)
    ffi.copy(blob_buf, blob, #blob)
    local kh = ffi.new("PVOID[1]")
    s = ffi.C.BCryptImportKeyPair(alg, nil, blob_type_w, kh,
                                   blob_buf, #blob, 0)
    if s ~= 0 then error(string.format("jwt: ECDSA import failed 0x%08X", s)) end
    return ffi.gc(kh[0], ffi.C.BCryptDestroyKey), alg
end

-- ===== RSA sign/verify =================================================

local function rsa_sign(key_obj, algo, digest)
    if type(key_obj) ~= "table" or type(key_obj.blob) ~= "string" then
        error("jwt: RS* algorithms require key = { blob = <BCRYPT_RSAPRIVATE_BLOB bytes> }")
    end
    -- Caller MUST supply a private-key blob for signing.
    local h_alg = ffi.new("PVOID[1]")
    local s = ffi.C.BCryptOpenAlgorithmProvider(h_alg, BC.RSA_ALGORITHM, nil, 0)
    if s ~= 0 then error(string.format("jwt: open RSA alg failed 0x%08X", s)) end
    local alg = ffi.gc(h_alg[0], function(p) ffi.C.BCryptCloseAlgorithmProvider(p, 0) end)
    local blob_buf = ffi.new("unsigned char[?]", #key_obj.blob)
    ffi.copy(blob_buf, key_obj.blob, #key_obj.blob)
    local kh = ffi.new("PVOID[1]")
    s = ffi.C.BCryptImportKeyPair(alg, nil, BC.BLOB_RSAPRIVATE, kh,
                                   blob_buf, #key_obj.blob, 0)
    if s ~= 0 then error(string.format("jwt: RSA private import failed 0x%08X", s)) end
    local key = ffi.gc(kh[0], ffi.C.BCryptDestroyKey)

    local pad = ffi.new("BCRYPT_PKCS1_PADDING_INFO")
    pad.pszAlgId = RS_PKCS1[algo]

    local dbuf = ffi.new("unsigned char[?]", #digest)
    ffi.copy(dbuf, digest, #digest)

    local sig_len = ffi.new("ULONG[1]")
    s = ffi.C.BCryptSignHash(key, pad, dbuf, #digest, nil, 0, sig_len, BC.BCRYPT_PAD_PKCS1)
    if s ~= 0 then error(string.format("jwt: RSA sign size query failed 0x%08X", s)) end
    local sig = ffi.new("unsigned char[?]", sig_len[0])
    s = ffi.C.BCryptSignHash(key, pad, dbuf, #digest, sig, sig_len[0], sig_len, BC.BCRYPT_PAD_PKCS1)
    if s ~= 0 then error(string.format("jwt: RSA sign failed 0x%08X", s)) end
    return ffi.string(sig, sig_len[0])
end

local function rsa_verify(key_obj, algo, digest, sig)
    if type(key_obj) ~= "table" or type(key_obj.blob) ~= "string" then
        return nil, "jwt: RS* verify requires { blob = <BCRYPT_RSAPUBLIC_BLOB bytes> }"
    end
    local key = import_rsa_public(key_obj.blob)
    local pad = ffi.new("BCRYPT_PKCS1_PADDING_INFO")
    pad.pszAlgId = RS_PKCS1[algo]
    local dbuf = ffi.new("unsigned char[?]", #digest)
    ffi.copy(dbuf, digest, #digest)
    local sbuf = ffi.new("unsigned char[?]", #sig)
    ffi.copy(sbuf, sig, #sig)
    local s = ffi.C.BCryptVerifySignature(key, pad, dbuf, #digest, sbuf, #sig, BC.BCRYPT_PAD_PKCS1)
    if s == 0 then return true end
    return nil, string.format("RSA verify failed 0x%08X", s)
end

-- ===== RSA-PSS sign/verify =============================================

local function rsa_pss_sign(key_obj, algo, digest)
    if type(key_obj) ~= "table" or type(key_obj.blob) ~= "string" then
        error("jwt: PS* algorithms require key = { blob = <BCRYPT_RSAPRIVATE_BLOB bytes> }")
    end
    local h_alg = ffi.new("PVOID[1]")
    local s = ffi.C.BCryptOpenAlgorithmProvider(h_alg, BC.RSA_ALGORITHM, nil, 0)
    if s ~= 0 then error(string.format("jwt: open RSA alg failed 0x%08X", s)) end
    local alg = ffi.gc(h_alg[0], function(p) ffi.C.BCryptCloseAlgorithmProvider(p, 0) end)
    local blob_buf = ffi.new("unsigned char[?]", #key_obj.blob)
    ffi.copy(blob_buf, key_obj.blob, #key_obj.blob)
    local kh = ffi.new("PVOID[1]")
    s = ffi.C.BCryptImportKeyPair(alg, nil, BC.BLOB_RSAPRIVATE, kh,
                                   blob_buf, #key_obj.blob, 0)
    if s ~= 0 then error(string.format("jwt: RSA private import failed 0x%08X", s)) end
    local key = ffi.gc(kh[0], ffi.C.BCryptDestroyKey)

    local pad = ffi.new("BCRYPT_PSS_PADDING_INFO")
    pad.pszAlgId = PSS_ALGID[algo]
    pad.cbSalt   = PSS_SALT[algo]

    local dbuf = ffi.new("unsigned char[?]", #digest)
    ffi.copy(dbuf, digest, #digest)
    local sig_len = ffi.new("ULONG[1]")
    s = ffi.C.BCryptSignHash(key, pad, dbuf, #digest, nil, 0, sig_len, BC.BCRYPT_PAD_PSS)
    if s ~= 0 then error(string.format("jwt: RSA-PSS sign size query failed 0x%08X", s)) end
    local sig = ffi.new("unsigned char[?]", sig_len[0])
    s = ffi.C.BCryptSignHash(key, pad, dbuf, #digest, sig, sig_len[0], sig_len, BC.BCRYPT_PAD_PSS)
    if s ~= 0 then error(string.format("jwt: RSA-PSS sign failed 0x%08X", s)) end
    return ffi.string(sig, sig_len[0])
end

local function rsa_pss_verify(key_obj, algo, digest, sig)
    if type(key_obj) ~= "table" or type(key_obj.blob) ~= "string" then
        return nil, "jwt: PS* verify requires { blob = <BCRYPT_RSAPUBLIC_BLOB bytes> }"
    end
    local key = import_rsa_public(key_obj.blob)
    local pad = ffi.new("BCRYPT_PSS_PADDING_INFO")
    pad.pszAlgId = PSS_ALGID[algo]
    pad.cbSalt   = PSS_SALT[algo]
    local dbuf = ffi.new("unsigned char[?]", #digest)
    ffi.copy(dbuf, digest, #digest)
    local sbuf = ffi.new("unsigned char[?]", #sig)
    ffi.copy(sbuf, sig, #sig)
    local s = ffi.C.BCryptVerifySignature(key, pad, dbuf, #digest, sbuf, #sig, BC.BCRYPT_PAD_PSS)
    if s == 0 then return true end
    return nil, string.format("RSA-PSS verify failed 0x%08X", s)
end

-- ===== ECDSA sign/verify ===============================================

local function ecdsa_curve_for(algo)
    return ES_INFO[algo]
end

local function ecdsa_sign(key_obj, algo, digest)
    if type(key_obj) ~= "table" or type(key_obj.blob) ~= "string" then
        error("jwt: ES* algorithms require key = { blob = <BCRYPT_ECCPRIVATE_BLOB bytes> }")
    end
    local info = ecdsa_curve_for(algo)
    local key = import_ecdsa(key_obj.blob, BC.BLOB_ECCPRIVATE, info.alg)
    local dbuf = ffi.new("unsigned char[?]", #digest)
    ffi.copy(dbuf, digest, #digest)
    local sig_len = ffi.new("ULONG[1]")
    local s = ffi.C.BCryptSignHash(key, nil, dbuf, #digest, nil, 0, sig_len, 0)
    if s ~= 0 then error(string.format("jwt: ECDSA sign size query failed 0x%08X", s)) end
    local sig = ffi.new("unsigned char[?]", sig_len[0])
    s = ffi.C.BCryptSignHash(key, nil, dbuf, #digest, sig, sig_len[0], sig_len, 0)
    if s ~= 0 then error(string.format("jwt: ECDSA sign failed 0x%08X", s)) end
    -- CNG already returns the JWT-style R||S concatenation (each half-padded).
    return ffi.string(sig, sig_len[0])
end

local function ecdsa_verify(key_obj, algo, digest, sig)
    if type(key_obj) ~= "table" or type(key_obj.blob) ~= "string" then
        return nil, "jwt: ES* verify requires { blob = <BCRYPT_ECCPUBLIC_BLOB bytes> }"
    end
    local info = ecdsa_curve_for(algo)
    if #sig ~= info.sig_size then
        return nil, string.format("ES%d signature must be %d bytes, got %d",
                                  ({ES256=256, ES384=384, ES512=521})[algo] or 0,
                                  info.sig_size, #sig)
    end
    local key = import_ecdsa(key_obj.blob, BC.BLOB_ECCPUBLIC, info.alg)
    local dbuf = ffi.new("unsigned char[?]", #digest)
    ffi.copy(dbuf, digest, #digest)
    local sbuf = ffi.new("unsigned char[?]", #sig)
    ffi.copy(sbuf, sig, #sig)
    local s = ffi.C.BCryptVerifySignature(key, nil, dbuf, #digest, sbuf, #sig, 0)
    if s == 0 then return true end
    return nil, string.format("ECDSA verify failed 0x%08X", s)
end

-- ===== Sign / verify front-end =========================================

local function signing_input(claims)
    local header  = json.encode({ alg = claims._alg, typ = "JWT" })
    local payload = json.encode(claims._claims)
    return b64url_encode(header) .. "." .. b64url_encode(payload)
end

function M.encode(claims, key, algo)
    if type(claims) ~= "table" then error("jwt.encode: claims must be a table") end
    if type(algo) ~= "string" then error("jwt.encode: algo required (HS256/RS256/...)") end
    local header_obj  = { alg = algo, typ = "JWT" }
    local header_str  = json.encode(header_obj)
    local payload_str = json.encode(claims)
    local input = b64url_encode(header_str) .. "." .. b64url_encode(payload_str)

    local sig
    if HS[algo] then
        if type(key) ~= "string" then error("jwt: HS* needs a string key") end
        sig = hmac.new(HS[algo], key):update(input):final()
    elseif RS[algo] then
        sig = rsa_sign(key, algo, jwt_hash(RS[algo], input))
    elseif PS[algo] then
        sig = rsa_pss_sign(key, algo, jwt_hash(PS[algo], input))
    elseif ES[algo] then
        sig = ecdsa_sign(key, algo, jwt_hash(ES[algo], input))
    elseif algo == "none" then
        -- Allow 'none' only if the caller explicitly asks for it -- but the verify
        -- side defaults to refusing 'none' to defend against the classic JWT attack.
        sig = ""
    else
        error("jwt.encode: unsupported algorithm '" .. algo .. "'")
    end
    return input .. "." .. b64url_encode(sig)
end

-- Split a "h.p.s" token into three parts; tolerate empty signature.
local function split3(token)
    local p1 = token:find(".", 1, true)
    if not p1 then return nil, "missing first '.'" end
    local p2 = token:find(".", p1 + 1, true)
    if not p2 then return nil, "missing second '.'" end
    return token:sub(1, p1 - 1),
           token:sub(p1 + 1, p2 - 1),
           token:sub(p2 + 1)
end

local function check_claims(claims, opts)
    opts = opts or {}
    local now    = opts.now or os.time()
    local leeway = opts.leeway or 0
    if claims.exp ~= nil and opts.verify_exp ~= false then
        if type(claims.exp) ~= "number" then return nil, "exp claim is not numeric" end
        if now > claims.exp + leeway then return nil, "token expired" end
    end
    if claims.nbf ~= nil and opts.verify_nbf ~= false then
        if type(claims.nbf) ~= "number" then return nil, "nbf claim is not numeric" end
        if now + leeway < claims.nbf then return nil, "token not yet valid" end
    end
    if claims.iat ~= nil and opts.verify_iat ~= false then
        if type(claims.iat) ~= "number" then return nil, "iat claim is not numeric" end
        -- Reject tokens claiming a future issuance time.
        if claims.iat > now + leeway then return nil, "iat claim is in the future" end
    end
    if opts.issuer  and claims.iss ~= opts.issuer  then return nil, "iss mismatch"  end
    if opts.subject and claims.sub ~= opts.subject then return nil, "sub mismatch" end
    if opts.audience then
        local want = opts.audience
        local got  = claims.aud
        local ok = false
        if type(got) == "string" then
            if type(want) == "string" then ok = (got == want)
            else for _, a in ipairs(want) do if a == got then ok = true; break end end end
        elseif type(got) == "table" then
            local set = {}
            for _, v in ipairs(got) do set[v] = true end
            if type(want) == "string" then ok = set[want] or false
            else for _, w in ipairs(want) do if set[w] then ok = true; break end end end
        end
        if not ok then return nil, "aud mismatch" end
    end
    return true
end

function M.decode(token, key, algo, opts)
    if type(token) ~= "string" then return nil, "token must be a string" end
    if type(algo)  ~= "string" then return nil, "expected algorithm required" end
    local h, p, s = split3(token)
    if not h then return nil, "malformed token: " .. p end

    local hdr_bytes = b64url_decode(h)
    local pl_bytes  = b64url_decode(p)
    local sig_bytes = b64url_decode(s)
    local input     = h .. "." .. p

    local ok_h, hdr = pcall(json.decode, hdr_bytes)
    if not ok_h then return nil, "bad header JSON" end
    if type(hdr) ~= "table" then return nil, "header is not an object" end
    if hdr.alg ~= algo then
        return nil, "alg mismatch: header says '" .. tostring(hdr.alg) .. "', expected '" .. algo .. "'"
    end
    if hdr.alg == "none" and not (opts and opts.allow_none) then
        return nil, "'none' algorithm rejected"
    end

    if HS[algo] then
        if type(key) ~= "string" then return nil, "HS* verify needs a string key" end
        local want = hmac.new(HS[algo], key):update(input):final()
        if #want ~= #sig_bytes then return nil, "signature length mismatch" end
        -- Constant-time compare
        local diff = 0
        for i = 1, #want do diff = diff | (want:byte(i) ~ sig_bytes:byte(i)) end
        if diff ~= 0 then return nil, "signature mismatch" end
    elseif RS[algo] then
        local ok, err = rsa_verify(key, algo, jwt_hash(RS[algo], input), sig_bytes)
        if not ok then return nil, err end
    elseif PS[algo] then
        local ok, err = rsa_pss_verify(key, algo, jwt_hash(PS[algo], input), sig_bytes)
        if not ok then return nil, err end
    elseif ES[algo] then
        local ok, err = ecdsa_verify(key, algo, jwt_hash(ES[algo], input), sig_bytes)
        if not ok then return nil, err end
    elseif algo == "none" then
        if sig_bytes ~= "" then return nil, "'none' algorithm must have empty signature" end
    else
        return nil, "unsupported algorithm '" .. algo .. "'"
    end

    local ok_p, claims = pcall(json.decode, pl_bytes)
    if not ok_p then return nil, "bad payload JSON" end
    if type(claims) ~= "table" then return nil, "payload is not an object" end

    local cok, cerr = check_claims(claims, opts)
    if not cok then return nil, cerr end
    return claims
end

M.verify = M.decode

-- ===== decode_unverified ==============================================
-- Returns { header, payload, signature_b64 } without checking the signature
-- or claim constraints. Intended for token inspection -- callers MUST NOT
-- act on the returned claims without subsequent verification.

function M.decode_unverified(token)
    if type(token) ~= "string" then return nil, "token must be a string" end
    local h, p, s = split3(token)
    if not h then return nil, "malformed token: " .. p end
    local ok_h, hdr = pcall(json.decode, b64url_decode(h))
    if not ok_h then return nil, "bad header JSON" end
    local ok_p, claims = pcall(json.decode, b64url_decode(p))
    if not ok_p then return nil, "bad payload JSON" end
    return { header = hdr, payload = claims, signature_b64 = s }
end

return M
