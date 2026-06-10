-- windows.bcrypt -- CNG (Cryptography Next Generation) modern crypto API.
-- Requires windows core for HANDLE, NTSTATUS, etc.
local W = require "windows"

ffi.cdef[[
NTSTATUS BCryptOpenAlgorithmProvider(PVOID *, LPCWSTR, LPCWSTR, ULONG);
NTSTATUS BCryptCloseAlgorithmProvider(PVOID, ULONG);
NTSTATUS BCryptGenRandom(PVOID, PVOID, ULONG, ULONG);
NTSTATUS BCryptCreateHash(PVOID, PVOID *, PVOID, ULONG, PVOID, ULONG, ULONG);
NTSTATUS BCryptHashData(PVOID, PVOID, ULONG, ULONG);
NTSTATUS BCryptFinishHash(PVOID, PVOID, ULONG, ULONG);
NTSTATUS BCryptDestroyHash(PVOID);
NTSTATUS BCryptGetProperty(PVOID, LPCWSTR, PVOID, ULONG, ULONG *, ULONG);
NTSTATUS BCryptSetProperty(PVOID, LPCWSTR, PVOID, ULONG, ULONG);
NTSTATUS BCryptGenerateSymmetricKey(PVOID, PVOID *, PVOID, ULONG, PVOID, ULONG, ULONG);
NTSTATUS BCryptDestroyKey(PVOID);
NTSTATUS BCryptEncrypt(PVOID, PVOID, ULONG, PVOID, PVOID, ULONG, PVOID, ULONG, ULONG *, ULONG);
NTSTATUS BCryptDecrypt(PVOID, PVOID, ULONG, PVOID, PVOID, ULONG, PVOID, ULONG, ULONG *, ULONG);

/* Asymmetric keys (RSA / ECDSA) */
NTSTATUS BCryptGenerateKeyPair(PVOID, PVOID *, ULONG, ULONG);
NTSTATUS BCryptFinalizeKeyPair(PVOID, ULONG);
NTSTATUS BCryptImportKeyPair(PVOID, PVOID, LPCWSTR, PVOID *, PVOID, ULONG, ULONG);
NTSTATUS BCryptExportKey(PVOID, PVOID, LPCWSTR, PVOID, ULONG, ULONG *, ULONG);
NTSTATUS BCryptSignHash(PVOID, PVOID, PVOID, ULONG, PVOID, ULONG, ULONG *, ULONG);
NTSTATUS BCryptVerifySignature(PVOID, PVOID, PVOID, ULONG, PVOID, ULONG, ULONG);

/* Password-based KDF (PBKDF2-HMAC-<hash>) */
NTSTATUS BCryptDeriveKeyPBKDF2(PVOID, PVOID, ULONG, PVOID, ULONG,
                               unsigned long long, PVOID, ULONG, ULONG);

/* AES-GCM / AES-CCM auth-mode info blob */
typedef struct _BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO {
    ULONG       cbSize;
    ULONG       dwInfoVersion;
    PVOID       pbNonce;
    ULONG       cbNonce;
    PVOID       pbAuthData;
    ULONG       cbAuthData;
    PVOID       pbTag;
    ULONG       cbTag;
    PVOID       pbMacContext;
    ULONG       cbMacContext;
    ULONG       cbAAD;
    unsigned long long cbData;
    ULONG       dwFlags;
} BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO;

/* RSA / ECC PKCS-style sign info blobs */
typedef struct _BCRYPT_PKCS1_PADDING_INFO {
    LPCWSTR pszAlgId;
} BCRYPT_PKCS1_PADDING_INFO;

typedef struct _BCRYPT_PSS_PADDING_INFO {
    LPCWSTR pszAlgId;
    ULONG   cbSalt;
} BCRYPT_PSS_PADDING_INFO;

/* RSA-key blob header (BCRYPT_RSAPUBLIC_BLOB / BCRYPT_RSAPRIVATE_BLOB) */
typedef struct _BCRYPT_RSAKEY_BLOB {
    ULONG Magic;
    ULONG BitLength;
    ULONG cbPublicExp;
    ULONG cbModulus;
    ULONG cbPrime1;
    ULONG cbPrime2;
} BCRYPT_RSAKEY_BLOB;

/* ECC-key blob header (BCRYPT_ECCPUBLIC_BLOB / BCRYPT_ECCPRIVATE_BLOB) */
typedef struct _BCRYPT_ECCKEY_BLOB {
    ULONG dwMagic;
    ULONG cbKey;
} BCRYPT_ECCKEY_BLOB;
]]
pcall(ffi.load, "bcrypt")

local M = {}

-- Algorithm name buffers (CNG expects null-terminated UTF-16).
local _ALG_NAMES = {
    SHA1_ALGORITHM      = "SHA1",
    SHA256_ALGORITHM    = "SHA256",
    SHA384_ALGORITHM    = "SHA384",
    SHA512_ALGORITHM    = "SHA512",
    MD5_ALGORITHM       = "MD5",
    AES_ALGORITHM       = "AES",
    RSA_ALGORITHM       = "RSA",
    RNG_ALGORITHM       = "RNG",
    ECDSA_P256_ALGORITHM = "ECDSA_P256",
    ECDSA_P384_ALGORITHM = "ECDSA_P384",
    ECDSA_P521_ALGORITHM = "ECDSA_P521",
    SHA3_256_ALGORITHM  = "SHA3-256",
    SHA3_384_ALGORITHM  = "SHA3-384",
    SHA3_512_ALGORITHM  = "SHA3-512",
}
for k, ascii in pairs(_ALG_NAMES) do
    local n = #ascii
    local w = ffi.new("unsigned short[?]", n + 1)
    for i = 1, n do w[i - 1] = string.byte(ascii, i) end
    w[n] = 0
    M[k] = w
end

-- Property / mode-name UTF-16 buffers
local _NAMES = {
    PROP_CHAINING_MODE   = "ChainingMode",
    PROP_BLOCK_LENGTH    = "BlockLength",
    PROP_OBJECT_LENGTH   = "ObjectLength",
    PROP_KEY_DATA_BLOB   = "KeyDataBlob",
    PROP_AUTH_TAG_LENGTH = "AuthTagLength",
    CHAIN_MODE_CBC       = "ChainingModeCBC",
    CHAIN_MODE_ECB       = "ChainingModeECB",
    CHAIN_MODE_CFB       = "ChainingModeCFB",
    CHAIN_MODE_GCM       = "ChainingModeGCM",
    CHAIN_MODE_CCM       = "ChainingModeCCM",
    BLOB_RSAPUBLIC       = "RSAPUBLICBLOB",
    BLOB_RSAPRIVATE      = "RSAPRIVATEBLOB",
    BLOB_ECCPUBLIC       = "ECCPUBLICBLOB",
    BLOB_ECCPRIVATE      = "ECCPRIVATEBLOB",
}
for k, ascii in pairs(_NAMES) do
    local n = #ascii
    local w = ffi.new("unsigned short[?]", n + 1)
    for i = 1, n do w[i - 1] = string.byte(ascii, i) end
    w[n] = 0
    M[k] = w
end

-- Common flags / magics
M.USE_SYSTEM_PREFERRED_RNG      = 0x00000002
M.BLOCK_PADDING                 = 0x00000001
M.BCRYPT_PAD_PKCS1              = 0x00000002
M.BCRYPT_PAD_PSS                = 0x00000008
M.BCRYPT_ALG_HANDLE_HMAC_FLAG   = 0x00000008  -- BCryptCreateHash: enable HMAC mode

M.RSAPUBLIC_MAGIC               = 0x31415352  -- 'RSA1'
M.RSAPRIVATE_MAGIC              = 0x32415352  -- 'RSA2'

-- ECC-key blob magic numbers (public + private variants per curve)
M.ECDSA_PUBLIC_P256_MAGIC       = 0x31534345
M.ECDSA_PRIVATE_P256_MAGIC      = 0x32534345
M.ECDSA_PUBLIC_P384_MAGIC       = 0x33534345
M.ECDSA_PRIVATE_P384_MAGIC      = 0x34534345
M.ECDSA_PUBLIC_P521_MAGIC       = 0x35534345
M.ECDSA_PRIVATE_P521_MAGIC      = 0x36534345

M.BCRYPT_AUTH_MODE_INFO_VERSION = 1

return M
