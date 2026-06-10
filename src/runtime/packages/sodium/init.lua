-- sodium -- libsodium modern cryptography bindings.
--
-- Sub-namespaces:
--   sodium.box        X25519 + XSalsa20-Poly1305 public-key authenticated encryption
--                     keypair() / encrypt(msg, nonce, pk, sk) / decrypt(c, nonce, pk, sk)
--                     seal(msg, pk) / seal_open(c, pk, sk)
--                     nonce()
--   sodium.sign       Ed25519 detached signatures
--                     keypair() / sign(msg, sk) / verify(sig, msg, pk)
--                     sk_to_pk(sk)
--   sodium.secretbox  XSalsa20-Poly1305 symmetric authenticated encryption
--                     key() / encrypt(msg, nonce, key) / decrypt(c, nonce, key)
--                     nonce()
--   sodium.aead       ChaCha20-Poly1305 + XChaCha20-Poly1305 AEAD
--                     chacha20poly1305.{key, nonce, encrypt, decrypt}
--                     xchacha20poly1305.{key, nonce, encrypt, decrypt}
--   sodium.hash       BLAKE2b generichash + helpers
--                     generic(bytes, key?, out_len?)
--                     sha256(bytes) / sha512(bytes)
--   sodium.pwhash     Argon2id / Argon2i password hashing
--                     str(password, opslimit?, memlimit?)
--                     str_verify(hash, password)
--                     hash(out_len, password, salt, opslimit?, memlimit?)
--   sodium.kx         X25519-based key exchange
--                     keypair() / client_session_keys(client_pk, client_sk, server_pk)
--                                / server_session_keys(server_pk, server_sk, client_pk)
--                     -- both return { rx = ..., tx = ... }
--   sodium.utils      randombytes(n) / bin2hex(s) / hex2bin(s) / memcmp(a, b)
--
-- All keys / nonces / ciphertexts are Lua strings (8-bit clean bytes).

local M = {}

ffi.cdef[[
int  sodium_init(void);
const char *sodium_version_string(void);
void sodium_memzero(void *buf, size_t len);
int  sodium_memcmp(const void *a, const void *b, size_t len);
char *sodium_bin2hex(char *hex, size_t hex_maxlen,
                     const unsigned char *bin, size_t bin_len);
int   sodium_hex2bin(unsigned char *bin, size_t bin_maxlen,
                     const char *hex, size_t hex_len,
                     const char *ignore, size_t *bin_len, const char **hex_end);

void randombytes_buf(void *buf, size_t size);

/* ===== crypto_box (X25519 + XSalsa20-Poly1305) ===== */
size_t crypto_box_publickeybytes(void);
size_t crypto_box_secretkeybytes(void);
size_t crypto_box_noncebytes(void);
size_t crypto_box_macbytes(void);
size_t crypto_box_sealbytes(void);

int crypto_box_keypair(unsigned char *pk, unsigned char *sk);
int crypto_box_easy(unsigned char *c, const unsigned char *m, unsigned long long mlen,
                    const unsigned char *n, const unsigned char *pk, const unsigned char *sk);
int crypto_box_open_easy(unsigned char *m, const unsigned char *c, unsigned long long clen,
                         const unsigned char *n, const unsigned char *pk, const unsigned char *sk);
int crypto_box_seal(unsigned char *c, const unsigned char *m, unsigned long long mlen,
                    const unsigned char *pk);
int crypto_box_seal_open(unsigned char *m, const unsigned char *c, unsigned long long clen,
                         const unsigned char *pk, const unsigned char *sk);

/* ===== crypto_sign (Ed25519) ===== */
size_t crypto_sign_publickeybytes(void);
size_t crypto_sign_secretkeybytes(void);
size_t crypto_sign_bytes(void);
size_t crypto_sign_seedbytes(void);

int crypto_sign_keypair(unsigned char *pk, unsigned char *sk);
int crypto_sign_seed_keypair(unsigned char *pk, unsigned char *sk, const unsigned char *seed);
int crypto_sign_detached(unsigned char *sig, unsigned long long *siglen,
                         const unsigned char *m, unsigned long long mlen,
                         const unsigned char *sk);
int crypto_sign_verify_detached(const unsigned char *sig,
                                const unsigned char *m, unsigned long long mlen,
                                const unsigned char *pk);
int crypto_sign_ed25519_sk_to_pk(unsigned char *pk, const unsigned char *sk);

/* ===== crypto_secretbox (XSalsa20-Poly1305) ===== */
size_t crypto_secretbox_keybytes(void);
size_t crypto_secretbox_noncebytes(void);
size_t crypto_secretbox_macbytes(void);

int crypto_secretbox_easy(unsigned char *c, const unsigned char *m, unsigned long long mlen,
                          const unsigned char *n, const unsigned char *k);
int crypto_secretbox_open_easy(unsigned char *m, const unsigned char *c, unsigned long long clen,
                               const unsigned char *n, const unsigned char *k);

/* ===== crypto_aead_chacha20poly1305_ietf ===== */
size_t crypto_aead_chacha20poly1305_ietf_keybytes(void);
size_t crypto_aead_chacha20poly1305_ietf_npubbytes(void);
size_t crypto_aead_chacha20poly1305_ietf_abytes(void);

int crypto_aead_chacha20poly1305_ietf_encrypt(
    unsigned char *c, unsigned long long *clen,
    const unsigned char *m, unsigned long long mlen,
    const unsigned char *ad, unsigned long long adlen,
    const unsigned char *nsec, const unsigned char *npub, const unsigned char *k);
int crypto_aead_chacha20poly1305_ietf_decrypt(
    unsigned char *m, unsigned long long *mlen,
    unsigned char *nsec,
    const unsigned char *c, unsigned long long clen,
    const unsigned char *ad, unsigned long long adlen,
    const unsigned char *npub, const unsigned char *k);

/* ===== crypto_aead_xchacha20poly1305_ietf ===== */
size_t crypto_aead_xchacha20poly1305_ietf_keybytes(void);
size_t crypto_aead_xchacha20poly1305_ietf_npubbytes(void);
size_t crypto_aead_xchacha20poly1305_ietf_abytes(void);

int crypto_aead_xchacha20poly1305_ietf_encrypt(
    unsigned char *c, unsigned long long *clen,
    const unsigned char *m, unsigned long long mlen,
    const unsigned char *ad, unsigned long long adlen,
    const unsigned char *nsec, const unsigned char *npub, const unsigned char *k);
int crypto_aead_xchacha20poly1305_ietf_decrypt(
    unsigned char *m, unsigned long long *mlen,
    unsigned char *nsec,
    const unsigned char *c, unsigned long long clen,
    const unsigned char *ad, unsigned long long adlen,
    const unsigned char *npub, const unsigned char *k);

/* ===== crypto_generichash (BLAKE2b) ===== */
size_t crypto_generichash_bytes(void);
size_t crypto_generichash_bytes_min(void);
size_t crypto_generichash_bytes_max(void);
size_t crypto_generichash_keybytes_max(void);

int crypto_generichash(unsigned char *out, size_t outlen,
                       const unsigned char *in, unsigned long long inlen,
                       const unsigned char *key, size_t keylen);

/* ===== crypto_hash (SHA-256 + SHA-512) ===== */
size_t crypto_hash_sha256_bytes(void);
size_t crypto_hash_sha512_bytes(void);
int    crypto_hash_sha256(unsigned char *out, const unsigned char *in, unsigned long long inlen);
int    crypto_hash_sha512(unsigned char *out, const unsigned char *in, unsigned long long inlen);

/* ===== crypto_pwhash (Argon2) ===== */
size_t crypto_pwhash_strbytes(void);
size_t crypto_pwhash_saltbytes(void);
size_t crypto_pwhash_bytes_min(void);
size_t crypto_pwhash_bytes_max(void);
unsigned long long crypto_pwhash_opslimit_interactive(void);
unsigned long long crypto_pwhash_opslimit_moderate(void);
unsigned long long crypto_pwhash_opslimit_sensitive(void);
size_t            crypto_pwhash_memlimit_interactive(void);
size_t            crypto_pwhash_memlimit_moderate(void);
size_t            crypto_pwhash_memlimit_sensitive(void);

int crypto_pwhash(unsigned char *out, unsigned long long outlen,
                  const char *passwd, unsigned long long passwdlen,
                  const unsigned char *salt,
                  unsigned long long opslimit, size_t memlimit, int alg);
int crypto_pwhash_str(char *out, const char *passwd, unsigned long long passwdlen,
                      unsigned long long opslimit, size_t memlimit);
int crypto_pwhash_str_verify(const char *str, const char *passwd, unsigned long long passwdlen);

/* ===== crypto_kx ===== */
size_t crypto_kx_publickeybytes(void);
size_t crypto_kx_secretkeybytes(void);
size_t crypto_kx_sessionkeybytes(void);

int crypto_kx_keypair(unsigned char *pk, unsigned char *sk);
int crypto_kx_client_session_keys(unsigned char *rx, unsigned char *tx,
                                  const unsigned char *client_pk, const unsigned char *client_sk,
                                  const unsigned char *server_pk);
int crypto_kx_server_session_keys(unsigned char *rx, unsigned char *tx,
                                  const unsigned char *server_pk, const unsigned char *server_sk,
                                  const unsigned char *client_pk);
]]

-- ===== Lazy DLL loader ===================================================

local _lib, _load_err, _inited

local function load_lib()
    if _lib then return _lib end
    if _load_err then return nil end
    local names = {}
    local env_dll = os.getenv("LUAVM_SODIUM_DLL")
    if env_dll and #env_dll > 0 then names[#names + 1] = env_dll end
    names[#names + 1] = "libsodium"
    names[#names + 1] = "libsodium.dll"
    names[#names + 1] = "sodium"
    names[#names + 1] = "sodium.dll"
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then _lib = lib; return lib end
    end
    _load_err = "sodium: libsodium.dll not found. "
        .. "Set LUAVM_SODIUM_DLL or drop libsodium.dll next to LuaVM."
    return nil
end

local function ensure_init(L)
    if _inited then return end
    -- sodium_init returns 0 first time, 1 if already initialized, <0 on error.
    -- Calling more than once is harmless.
    local rc = L.sodium_init()
    if rc < 0 then
        error("sodium: sodium_init failed (" .. tostring(rc) .. ")", 3)
    end
    _inited = true
end

local function require_lib()
    local L = load_lib()
    if L == nil then error(_load_err, 3) end
    ensure_init(L)
    return L
end

function M.available()
    return load_lib() ~= nil
end

function M.version()
    local L = load_lib()
    if L == nil then return "?" end
    local s = L.sodium_version_string()
    return s ~= nil and ffi.string(s) or "?"
end

-- ===== Tiny helpers ======================================================

local function alloc_str(n)
    return ffi.new("unsigned char[?]", n)
end

local function as_bytes(s)
    return ffi.cast("const unsigned char *", s)
end

-- ===== utils sub-namespace ==============================================

M.utils = {}

function M.utils.randombytes(n)
    local L = require_lib()
    if type(n) ~= "number" or n < 1 then
        error("sodium.utils.randombytes: n must be a positive integer", 2)
    end
    local buf = alloc_str(n)
    L.randombytes_buf(buf, n)
    return ffi.string(buf, n)
end

function M.utils.bin2hex(bin)
    local L = require_lib()
    if type(bin) ~= "string" then error("sodium.utils.bin2hex: expected string", 2) end
    local n = #bin
    local out = ffi.new("char[?]", n * 2 + 1)
    L.sodium_bin2hex(out, n * 2 + 1, as_bytes(bin), n)
    return ffi.string(out, n * 2)
end

function M.utils.hex2bin(hex)
    local L = require_lib()
    if type(hex) ~= "string" then error("sodium.utils.hex2bin: expected string", 2) end
    local max = math.floor(#hex / 2)
    local out = ffi.new("unsigned char[?]", math.max(max, 1))
    local bin_len = ffi.new("size_t[1]")
    if L.sodium_hex2bin(out, max, hex, #hex, nil, bin_len, nil) ~= 0 then
        error("sodium.utils.hex2bin: malformed hex", 2)
    end
    return ffi.string(out, tonumber(bin_len[0]))
end

function M.utils.memcmp(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        error("sodium.utils.memcmp: expected two strings", 2)
    end
    if #a ~= #b then return false end
    local L = require_lib()
    return L.sodium_memcmp(as_bytes(a), as_bytes(b), #a) == 0
end

-- ===== box sub-namespace ================================================

M.box = {}

function M.box.keypair()
    local L = require_lib()
    local pk_n = tonumber(L.crypto_box_publickeybytes())
    local sk_n = tonumber(L.crypto_box_secretkeybytes())
    local pk = alloc_str(pk_n); local sk = alloc_str(sk_n)
    if L.crypto_box_keypair(pk, sk) ~= 0 then
        error("sodium.box.keypair: keypair generation failed", 2)
    end
    return { pk = ffi.string(pk, pk_n), sk = ffi.string(sk, sk_n) }
end

function M.box.nonce()
    local L = require_lib()
    local n = tonumber(L.crypto_box_noncebytes())
    return M.utils.randombytes(n)
end

function M.box.encrypt(msg, nonce, pk, sk)
    local L = require_lib()
    local mac_n = tonumber(L.crypto_box_macbytes())
    local c_n = #msg + mac_n
    local c = alloc_str(c_n)
    if L.crypto_box_easy(c, as_bytes(msg), #msg, as_bytes(nonce),
                         as_bytes(pk), as_bytes(sk)) ~= 0 then
        error("sodium.box.encrypt: failed", 2)
    end
    return ffi.string(c, c_n)
end

function M.box.decrypt(ciphertext, nonce, pk, sk)
    local L = require_lib()
    local mac_n = tonumber(L.crypto_box_macbytes())
    if #ciphertext < mac_n then
        error("sodium.box.decrypt: ciphertext too short", 2)
    end
    local m_n = #ciphertext - mac_n
    local m = alloc_str(math.max(m_n, 1))
    if L.crypto_box_open_easy(m, as_bytes(ciphertext), #ciphertext,
                              as_bytes(nonce), as_bytes(pk), as_bytes(sk)) ~= 0 then
        error("sodium.box.decrypt: authentication failed", 2)
    end
    return ffi.string(m, m_n)
end

function M.box.seal(msg, pk)
    local L = require_lib()
    local seal_n = tonumber(L.crypto_box_sealbytes())
    local c_n = #msg + seal_n
    local c = alloc_str(c_n)
    if L.crypto_box_seal(c, as_bytes(msg), #msg, as_bytes(pk)) ~= 0 then
        error("sodium.box.seal: failed", 2)
    end
    return ffi.string(c, c_n)
end

function M.box.seal_open(ciphertext, pk, sk)
    local L = require_lib()
    local seal_n = tonumber(L.crypto_box_sealbytes())
    if #ciphertext < seal_n then
        error("sodium.box.seal_open: ciphertext too short", 2)
    end
    local m_n = #ciphertext - seal_n
    local m = alloc_str(math.max(m_n, 1))
    if L.crypto_box_seal_open(m, as_bytes(ciphertext), #ciphertext,
                              as_bytes(pk), as_bytes(sk)) ~= 0 then
        error("sodium.box.seal_open: authentication failed", 2)
    end
    return ffi.string(m, m_n)
end

-- ===== sign sub-namespace ===============================================

M.sign = {}

function M.sign.keypair()
    local L = require_lib()
    local pk_n = tonumber(L.crypto_sign_publickeybytes())
    local sk_n = tonumber(L.crypto_sign_secretkeybytes())
    local pk = alloc_str(pk_n); local sk = alloc_str(sk_n)
    if L.crypto_sign_keypair(pk, sk) ~= 0 then
        error("sodium.sign.keypair: failed", 2)
    end
    return { pk = ffi.string(pk, pk_n), sk = ffi.string(sk, sk_n) }
end

function M.sign.sign(msg, sk)
    local L = require_lib()
    local sig_n = tonumber(L.crypto_sign_bytes())
    local sig = alloc_str(sig_n)
    local sig_len = ffi.new("unsigned long long[1]")
    if L.crypto_sign_detached(sig, sig_len, as_bytes(msg), #msg, as_bytes(sk)) ~= 0 then
        error("sodium.sign.sign: failed", 2)
    end
    return ffi.string(sig, tonumber(sig_len[0]))
end

function M.sign.verify(sig, msg, pk)
    local L = require_lib()
    return L.crypto_sign_verify_detached(as_bytes(sig), as_bytes(msg), #msg, as_bytes(pk)) == 0
end

function M.sign.sk_to_pk(sk)
    local L = require_lib()
    local pk_n = tonumber(L.crypto_sign_publickeybytes())
    local pk = alloc_str(pk_n)
    if L.crypto_sign_ed25519_sk_to_pk(pk, as_bytes(sk)) ~= 0 then
        error("sodium.sign.sk_to_pk: failed", 2)
    end
    return ffi.string(pk, pk_n)
end

-- ===== secretbox sub-namespace ==========================================

M.secretbox = {}

function M.secretbox.key()
    local L = require_lib()
    local n = tonumber(L.crypto_secretbox_keybytes())
    return M.utils.randombytes(n)
end

function M.secretbox.nonce()
    local L = require_lib()
    local n = tonumber(L.crypto_secretbox_noncebytes())
    return M.utils.randombytes(n)
end

function M.secretbox.encrypt(msg, nonce, key)
    local L = require_lib()
    local mac_n = tonumber(L.crypto_secretbox_macbytes())
    local c_n = #msg + mac_n
    local c = alloc_str(c_n)
    if L.crypto_secretbox_easy(c, as_bytes(msg), #msg, as_bytes(nonce), as_bytes(key)) ~= 0 then
        error("sodium.secretbox.encrypt: failed", 2)
    end
    return ffi.string(c, c_n)
end

function M.secretbox.decrypt(c, nonce, key)
    local L = require_lib()
    local mac_n = tonumber(L.crypto_secretbox_macbytes())
    if #c < mac_n then
        error("sodium.secretbox.decrypt: ciphertext too short", 2)
    end
    local m_n = #c - mac_n
    local m = alloc_str(math.max(m_n, 1))
    if L.crypto_secretbox_open_easy(m, as_bytes(c), #c, as_bytes(nonce), as_bytes(key)) ~= 0 then
        error("sodium.secretbox.decrypt: authentication failed", 2)
    end
    return ffi.string(m, m_n)
end

-- ===== aead sub-namespace ===============================================
-- Two AEAD ciphers exposed -- ChaCha20-Poly1305-IETF (96-bit nonce) and
-- XChaCha20-Poly1305-IETF (192-bit nonce, safe for random nonces).

M.aead = {}

local function build_aead(getters, encrypt_fn, decrypt_fn)
    local sub = {}
    function sub.key()
        local L = require_lib()
        return M.utils.randombytes(tonumber(getters.key_n(L)))
    end
    function sub.nonce()
        local L = require_lib()
        return M.utils.randombytes(tonumber(getters.nonce_n(L)))
    end
    function sub.encrypt(msg, nonce, key, aad)
        local L = require_lib()
        local mac_n = tonumber(getters.mac_n(L))
        local c_n = #msg + mac_n
        local c = alloc_str(c_n)
        local clen = ffi.new("unsigned long long[1]")
        local ad_ptr = aad and as_bytes(aad) or nil
        local ad_len = aad and #aad or 0
        if L[encrypt_fn](c, clen, as_bytes(msg), #msg, ad_ptr, ad_len,
                        nil, as_bytes(nonce), as_bytes(key)) ~= 0 then
            error("sodium.aead.encrypt: failed", 2)
        end
        return ffi.string(c, tonumber(clen[0]))
    end
    function sub.decrypt(ciphertext, nonce, key, aad)
        local L = require_lib()
        local m = alloc_str(math.max(#ciphertext, 1))
        local mlen = ffi.new("unsigned long long[1]")
        local ad_ptr = aad and as_bytes(aad) or nil
        local ad_len = aad and #aad or 0
        if L[decrypt_fn](m, mlen, nil, as_bytes(ciphertext), #ciphertext,
                        ad_ptr, ad_len, as_bytes(nonce), as_bytes(key)) ~= 0 then
            error("sodium.aead.decrypt: authentication failed", 2)
        end
        return ffi.string(m, tonumber(mlen[0]))
    end
    return sub
end

M.aead.chacha20poly1305 = build_aead({
    key_n   = function(L) return L.crypto_aead_chacha20poly1305_ietf_keybytes() end,
    nonce_n = function(L) return L.crypto_aead_chacha20poly1305_ietf_npubbytes() end,
    mac_n   = function(L) return L.crypto_aead_chacha20poly1305_ietf_abytes() end,
}, "crypto_aead_chacha20poly1305_ietf_encrypt",
   "crypto_aead_chacha20poly1305_ietf_decrypt")

M.aead.xchacha20poly1305 = build_aead({
    key_n   = function(L) return L.crypto_aead_xchacha20poly1305_ietf_keybytes() end,
    nonce_n = function(L) return L.crypto_aead_xchacha20poly1305_ietf_npubbytes() end,
    mac_n   = function(L) return L.crypto_aead_xchacha20poly1305_ietf_abytes() end,
}, "crypto_aead_xchacha20poly1305_ietf_encrypt",
   "crypto_aead_xchacha20poly1305_ietf_decrypt")

-- ===== hash sub-namespace ===============================================

M.hash = {}

function M.hash.generic(bytes, key, out_len)
    local L = require_lib()
    local default_n = tonumber(L.crypto_generichash_bytes())
    out_len = out_len or default_n
    local out = alloc_str(out_len)
    local key_ptr = key and as_bytes(key) or nil
    local key_len = key and #key or 0
    if L.crypto_generichash(out, out_len, as_bytes(bytes), #bytes, key_ptr, key_len) ~= 0 then
        error("sodium.hash.generic: failed", 2)
    end
    return ffi.string(out, out_len)
end

function M.hash.sha256(bytes)
    local L = require_lib()
    local n = tonumber(L.crypto_hash_sha256_bytes())
    local out = alloc_str(n)
    if L.crypto_hash_sha256(out, as_bytes(bytes), #bytes) ~= 0 then
        error("sodium.hash.sha256: failed", 2)
    end
    return ffi.string(out, n)
end

function M.hash.sha512(bytes)
    local L = require_lib()
    local n = tonumber(L.crypto_hash_sha512_bytes())
    local out = alloc_str(n)
    if L.crypto_hash_sha512(out, as_bytes(bytes), #bytes) ~= 0 then
        error("sodium.hash.sha512: failed", 2)
    end
    return ffi.string(out, n)
end

-- ===== pwhash sub-namespace =============================================

M.pwhash = {}

function M.pwhash.salt()
    local L = require_lib()
    local n = tonumber(L.crypto_pwhash_saltbytes())
    return M.utils.randombytes(n)
end

function M.pwhash.str(password, opslimit, memlimit)
    local L = require_lib()
    local n = tonumber(L.crypto_pwhash_strbytes())
    local out = ffi.new("char[?]", n)
    opslimit = opslimit or tonumber(L.crypto_pwhash_opslimit_interactive())
    memlimit = memlimit or tonumber(L.crypto_pwhash_memlimit_interactive())
    if L.crypto_pwhash_str(out, password, #password, opslimit, memlimit) ~= 0 then
        error("sodium.pwhash.str: failed (out of memory?)", 2)
    end
    return ffi.string(out)
end

function M.pwhash.str_verify(stored_hash, password)
    local L = require_lib()
    return L.crypto_pwhash_str_verify(stored_hash, password, #password) == 0
end

function M.pwhash.hash(out_len, password, salt, opslimit, memlimit)
    local L = require_lib()
    opslimit = opslimit or tonumber(L.crypto_pwhash_opslimit_interactive())
    memlimit = memlimit or tonumber(L.crypto_pwhash_memlimit_interactive())
    if out_len < tonumber(L.crypto_pwhash_bytes_min()) then
        error("sodium.pwhash.hash: out_len below minimum", 2)
    end
    local out = alloc_str(out_len)
    -- alg = 2 (Argon2id) -- fixed; the explicit-Argon2i version is rarely needed.
    if L.crypto_pwhash(out, out_len, password, #password,
                       as_bytes(salt), opslimit, memlimit, 2) ~= 0 then
        error("sodium.pwhash.hash: failed", 2)
    end
    return ffi.string(out, out_len)
end

-- ===== kx sub-namespace =================================================

M.kx = {}

function M.kx.keypair()
    local L = require_lib()
    local pk_n = tonumber(L.crypto_kx_publickeybytes())
    local sk_n = tonumber(L.crypto_kx_secretkeybytes())
    local pk = alloc_str(pk_n); local sk = alloc_str(sk_n)
    if L.crypto_kx_keypair(pk, sk) ~= 0 then
        error("sodium.kx.keypair: failed", 2)
    end
    return { pk = ffi.string(pk, pk_n), sk = ffi.string(sk, sk_n) }
end

function M.kx.client_session_keys(client_pk, client_sk, server_pk)
    local L = require_lib()
    local n = tonumber(L.crypto_kx_sessionkeybytes())
    local rx = alloc_str(n); local tx = alloc_str(n)
    if L.crypto_kx_client_session_keys(rx, tx,
        as_bytes(client_pk), as_bytes(client_sk), as_bytes(server_pk)) ~= 0 then
        error("sodium.kx.client_session_keys: peer key rejected", 2)
    end
    return { rx = ffi.string(rx, n), tx = ffi.string(tx, n) }
end

function M.kx.server_session_keys(server_pk, server_sk, client_pk)
    local L = require_lib()
    local n = tonumber(L.crypto_kx_sessionkeybytes())
    local rx = alloc_str(n); local tx = alloc_str(n)
    if L.crypto_kx_server_session_keys(rx, tx,
        as_bytes(server_pk), as_bytes(server_sk), as_bytes(client_pk)) ~= 0 then
        error("sodium.kx.server_session_keys: peer key rejected", 2)
    end
    return { rx = ffi.string(rx, n), tx = ffi.string(tx, n) }
end

return M
