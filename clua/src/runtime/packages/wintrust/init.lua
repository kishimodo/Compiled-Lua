-- wintrust -- Authenticode signature verification.
--
-- Public surface:
--   wintrust.verify(path, opts?)         -> result
--   wintrust.is_signed(path)             -> bool
--   wintrust.signer_info(path)           -> { name, thumbprint, issuer, ... }
--   wintrust.get_signatures(path)        -> { sig, ... }  (embedded + catalog)
--   wintrust.verify_catalog(path, cat_path) -> result
--   wintrust.file_hash(path, algo?)      -> bytes  (SHA-256 by default)
--   wintrust.cat_lookup_by_hash(hash)    -> catalog path | nil
--
-- opts:
--   revocation_check = "online" | "cached" | "none"   default "cached"
--   ui               = "none" | "prompt"              default "none"
--   timestamp        = bool                            request timestamp (default true)
--
-- result:
--   { valid, trust_status, signer_name, signer_thumbprint, timestamp,
--     subject, issuer, serial, certificates = { {subject, issuer, ...} } }

local W = require "windows"

ffi.cdef[[
typedef void * HCATADMIN;
typedef void * HCATINFO;
typedef void * HCRYPTMSG;
typedef void * HCERTSTORE;
typedef void * PCCERT_CONTEXT;

/* WinVerifyTrust file info union member */
typedef struct _WINTRUST_FILE_INFO {
    DWORD     cbStruct;
    LPCWSTR   pcwszFilePath;
    HANDLE    hFile;
    void     *pgKnownSubject;
} WINTRUST_FILE_INFO;

typedef struct _WINTRUST_CATALOG_INFO {
    DWORD     cbStruct;
    DWORD     dwCatalogVersion;
    LPCWSTR   pcwszCatalogFilePath;
    LPCWSTR   pcwszMemberTag;
    LPCWSTR   pcwszMemberFilePath;
    HANDLE    hMemberFile;
    BYTE     *pbCalculatedFileHash;
    DWORD     cbCalculatedFileHash;
    void     *pcCatalogContext;
    HCATADMIN hCatAdmin;
} WINTRUST_CATALOG_INFO;

typedef struct _WINTRUST_DATA {
    DWORD     cbStruct;
    void     *pPolicyCallbackData;
    void     *pSIPClientData;
    DWORD     dwUIChoice;
    DWORD     fdwRevocationChecks;
    DWORD     dwUnionChoice;
    void     *pInfoUnion;   /* WINTRUST_FILE_INFO * or WINTRUST_CATALOG_INFO * */
    DWORD     dwStateAction;
    HANDLE    hWVTStateData;
    LPCWSTR   pwszURLReference;
    DWORD     dwProvFlags;
    DWORD     dwUIContext;
    void     *pSignatureSettings;
} WINTRUST_DATA;

typedef struct _GUID_WT {
    DWORD Data1; WORD Data2; WORD Data3; BYTE Data4[8];
} GUID_WT;

LONG WinVerifyTrust(HWND hwnd, GUID_WT *pgActionID, void *pWVTData);

/* ===== Catalog (driver-store) signature lookup ===== */
BOOL CryptCATAdminAcquireContext(HCATADMIN *phCatAdmin, void *pgSubsystem, DWORD dwFlags);
BOOL CryptCATAdminAcquireContext2(HCATADMIN *phCatAdmin, void *pgSubsystem,
                                  LPCWSTR pwszHashAlgorithm, void *pStrongHashPolicy,
                                  DWORD dwFlags);
BOOL CryptCATAdminReleaseContext(HCATADMIN hCatAdmin, DWORD dwFlags);
BOOL CryptCATAdminCalcHashFromFileHandle(HANDLE hFile, DWORD *pcbHash, BYTE *pbHash, DWORD dwFlags);
BOOL CryptCATAdminCalcHashFromFileHandle2(HCATADMIN hCatAdmin, HANDLE hFile,
                                          DWORD *pcbHash, BYTE *pbHash, DWORD dwFlags);
HCATINFO CryptCATAdminEnumCatalogFromHash(HCATADMIN hCatAdmin, BYTE *pbHash,
                                          DWORD cbHash, DWORD dwFlags,
                                          HCATINFO *phPrevCatInfo);
BOOL CryptCATAdminReleaseCatalogContext(HCATADMIN hCatAdmin, HCATINFO hCatInfo, DWORD dwFlags);

typedef struct _CATALOG_INFO_WT {
    DWORD cbStruct;
    unsigned short wszCatalogFile[260];
} CATALOG_INFO_WT;
BOOL CryptCATCatalogInfoFromContext(HCATINFO hCatInfo, CATALOG_INFO_WT *psCatInfo, DWORD dwFlags);

/* ===== crypt32: signer / cert chain enumeration ===== */
BOOL CryptQueryObject(DWORD dwObjectType, const void *pvObject, DWORD dwExpectedContentTypeFlags,
                      DWORD dwExpectedFormatTypeFlags, DWORD dwFlags,
                      DWORD *pdwMsgAndCertEncodingType, DWORD *pdwContentType,
                      DWORD *pdwFormatType, HCERTSTORE *phCertStore,
                      HCRYPTMSG *phMsg, const void **ppvContext);
BOOL CryptMsgGetParam(HCRYPTMSG hCryptMsg, DWORD dwParamType, DWORD dwIndex,
                      void *pvData, DWORD *pcbData);
BOOL CryptMsgClose(HCRYPTMSG hCryptMsg);
BOOL CertCloseStore(HCERTSTORE hCertStore, DWORD dwFlags);

typedef struct _CERT_NAME_BLOB_WT {
    DWORD cbData;
    BYTE *pbData;
} CERT_NAME_BLOB_WT;

typedef struct _CERT_INFO_WT {
    DWORD    dwVersion;
    CERT_NAME_BLOB_WT SerialNumber;
    struct { LPSTR pszObjId; CERT_NAME_BLOB_WT Parameters; } SignatureAlgorithm;
    CERT_NAME_BLOB_WT Issuer;
    FILETIME NotBefore;
    FILETIME NotAfter;
    CERT_NAME_BLOB_WT Subject;
    /* remaining fields elided -- we only touch the above */
} CERT_INFO_WT;

typedef struct _CERT_CONTEXT_WT {
    DWORD       dwCertEncodingType;
    BYTE       *pbCertEncoded;
    DWORD       cbCertEncoded;
    CERT_INFO_WT *pCertInfo;
    HCERTSTORE  hCertStore;
} CERT_CONTEXT_WT;

PCCERT_CONTEXT CertFindCertificateInStore(HCERTSTORE hCertStore, DWORD dwCertEncodingType,
                                          DWORD dwFindFlags, DWORD dwFindType,
                                          const void *pvFindPara, PCCERT_CONTEXT pPrevCertContext);
PCCERT_CONTEXT CertEnumCertificatesInStore(HCERTSTORE hCertStore, PCCERT_CONTEXT pPrevCertContext);
DWORD CertGetNameStringW(PCCERT_CONTEXT pCertContext, DWORD dwType, DWORD dwFlags,
                         void *pvTypePara, LPWSTR pszNameString, DWORD cchNameString);
BOOL  CertGetCertificateContextProperty(PCCERT_CONTEXT pCertContext, DWORD dwPropId,
                                        void *pvData, DWORD *pcbData);
BOOL  CertFreeCertificateContext(PCCERT_CONTEXT pCertContext);

/* Hash (BCryptHash one-shot) -- we declare locally to avoid pulling in windows.bcrypt */
NTSTATUS BCryptHash(PVOID hAlgorithm, PVOID pbSecret, ULONG cbSecret,
                    PVOID pbInput, ULONG cbInput, PVOID pbOutput, ULONG cbOutput);
NTSTATUS BCryptOpenAlgorithmProvider(PVOID *phAlgorithm, LPCWSTR pszAlgId,
                                     LPCWSTR pszImplementation, ULONG dwFlags);
NTSTATUS BCryptCloseAlgorithmProvider(PVOID hAlgorithm, ULONG dwFlags);
]]

pcall(ffi.load, "wintrust")
pcall(ffi.load, "crypt32")
pcall(ffi.load, "bcrypt")

local C = ffi.C
local M = {}

-- ===== Trust action GUIDs ==============================================
-- WINTRUST_ACTION_GENERIC_VERIFY_V2 = {00aac56b-cd44-11d0-8cc2-00c04fc295ee}
local function make_guid(d1, d2, d3, d4_bytes)
    local g = ffi.new("GUID_WT")
    g.Data1 = d1; g.Data2 = d2; g.Data3 = d3
    for i = 1, 8 do g.Data4[i - 1] = d4_bytes[i] end
    return g
end

M.GENERIC_VERIFY_V2 = make_guid(0x00AAC56B, 0xCD44, 0x11D0,
    { 0x8C, 0xC2, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE })
M.DRIVER_ACTION_VERIFY = make_guid(0xF750E6C3, 0x38EE, 0x11D1,
    { 0x85, 0xE5, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE })

-- ===== Constants =======================================================
M.WTD_UI_ALL              = 1
M.WTD_UI_NONE             = 2
M.WTD_UI_NOBAD            = 3
M.WTD_UI_NOGOOD           = 4

M.WTD_REVOKE_NONE         = 0
M.WTD_REVOKE_WHOLECHAIN   = 1

M.WTD_CHOICE_FILE         = 1
M.WTD_CHOICE_CATALOG      = 2
M.WTD_CHOICE_BLOB         = 3
M.WTD_CHOICE_SIGNER       = 4
M.WTD_CHOICE_CERT         = 5

M.WTD_STATEACTION_IGNORE        = 0
M.WTD_STATEACTION_VERIFY        = 1
M.WTD_STATEACTION_CLOSE         = 2
M.WTD_STATEACTION_AUTO_CACHE    = 3
M.WTD_STATEACTION_AUTO_CACHE_FLUSH = 4

M.WTD_USE_DEFAULT_OSVER_CHECK   = 0x4
M.WTD_REVOCATION_CHECK_NONE     = 0x10
M.WTD_REVOCATION_CHECK_END_CERT = 0x20
M.WTD_REVOCATION_CHECK_CHAIN    = 0x40
M.WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT = 0x80
M.WTD_SAFER_FLAG                = 0x100
M.WTD_HASH_ONLY_FLAG            = 0x200
M.WTD_USE_DEFAULT_OSVER_CHECK   = 0x400
M.WTD_LIFETIME_SIGNING_FLAG     = 0x800
M.WTD_CACHE_ONLY_URL_RETRIEVAL  = 0x1000
M.WTD_DISABLE_MD2_MD4           = 0x2000
M.WTD_MOTW                      = 0x4000

-- CryptQueryObject parameters
local CERT_QUERY_OBJECT_FILE                = 0x1
local CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED = 0x400
local CERT_QUERY_FORMAT_FLAG_BINARY         = 0x2
local PKCS_7_ASN_ENCODING                   = 0x10000
local X509_ASN_ENCODING                     = 0x1

-- CryptMsgGetParam types
local CMSG_SIGNER_INFO_PARAM         = 6
local CMSG_SIGNER_COUNT_PARAM        = 5
local CMSG_CONTENT_PARAM             = 2

-- CertGetNameString name types
local CERT_NAME_SIMPLE_DISPLAY_TYPE  = 4
local CERT_NAME_ISSUER_FLAG          = 0x1

-- CertGetCertificateContextProperty
local CERT_SHA1_HASH_PROP_ID         = 3
local CERT_SHA256_HASH_PROP_ID       = 102

-- CertFindCertificateInStore find types
local CERT_FIND_SUBJECT_NAME         = 0x00070007
local CERT_FIND_SHA1_HASH            = 0x10000

-- TRUST_E_NOSIGNATURE / TRUST_E_PROVIDER_UNKNOWN / etc
local TRUST_E_NOSIGNATURE            = 0x800B0100
local TRUST_E_BAD_DIGEST             = 0x80096010
local CERT_E_EXPIRED                 = 0x800B0101
local CRYPT_E_NO_MATCH               = 0x80092004
local CRYPT_E_NOT_FOUND              = 0x80092004

-- ===== helpers =========================================================

local function flags_for(opts)
    opts = opts or {}
    local flags = 0
    local rev = opts.revocation_check or "cached"
    if rev == "none" then
        flags = flags + M.WTD_REVOCATION_CHECK_NONE
    elseif rev == "online" then
        flags = flags + M.WTD_REVOCATION_CHECK_CHAIN
    else -- "cached"
        flags = flags + M.WTD_REVOCATION_CHECK_CHAIN
        flags = flags + M.WTD_CACHE_ONLY_URL_RETRIEVAL
    end
    return flags
end

local function ui_for(opts)
    if not opts or opts.ui == nil or opts.ui == "none" then
        return M.WTD_UI_NONE
    end
    return M.WTD_UI_ALL
end

local function build_file_wvt(path, opts)
    local wpath = W.ToWide(path)
    local fi = ffi.new("WINTRUST_FILE_INFO")
    fi.cbStruct = ffi.sizeof("WINTRUST_FILE_INFO")
    fi.pcwszFilePath = wpath
    fi.hFile = nil
    fi.pgKnownSubject = nil

    local wd = ffi.new("WINTRUST_DATA")
    wd.cbStruct = ffi.sizeof("WINTRUST_DATA")
    wd.dwUIChoice = ui_for(opts)
    wd.fdwRevocationChecks = M.WTD_REVOKE_NONE
    wd.dwUnionChoice = M.WTD_CHOICE_FILE
    wd.pInfoUnion = fi
    wd.dwStateAction = M.WTD_STATEACTION_VERIFY
    wd.dwProvFlags = flags_for(opts)
    wd.dwUIContext = 0
    -- Anchor strings so they outlive the call.
    return wd, fi, wpath
end

local function close_wvt(wd)
    wd.dwStateAction = M.WTD_STATEACTION_CLOSE
    -- Use the same GUID as the verify call.
    C.WinVerifyTrust(nil, M.GENERIC_VERIFY_V2, wd)
end

-- ===== certificate enumeration via CryptQueryObject ====================

local function get_cert_name(ctx, name_type, flags)
    name_type = name_type or CERT_NAME_SIMPLE_DISPLAY_TYPE
    flags = flags or 0
    -- size query
    local n = tonumber(C.CertGetNameStringW(ctx, name_type, flags, nil, nil, 0))
    if n <= 1 then return "" end
    local buf = ffi.new("unsigned short[?]", n)
    C.CertGetNameStringW(ctx, name_type, flags, nil, buf, n)
    return W.FromWide(buf)
end

local function get_cert_thumbprint(ctx, prop_id)
    prop_id = prop_id or CERT_SHA1_HASH_PROP_ID
    local cb = ffi.new("DWORD[1]")
    if C.CertGetCertificateContextProperty(ctx, prop_id, nil, cb) == 0 then
        return nil
    end
    local buf = ffi.new("uint8_t[?]", cb[0])
    if C.CertGetCertificateContextProperty(ctx, prop_id, buf, cb) == 0 then
        return nil
    end
    local out = {}
    for i = 0, tonumber(cb[0]) - 1 do
        out[#out + 1] = string.format("%02X", buf[i])
    end
    return table.concat(out)
end

local function enum_store_certs(store)
    local certs = {}
    local prev = nil
    while true do
        local ctx = C.CertEnumCertificatesInStore(store, prev)
        if ctx == nil then break end
        certs[#certs + 1] = {
            subject    = get_cert_name(ctx, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0),
            issuer     = get_cert_name(ctx, CERT_NAME_SIMPLE_DISPLAY_TYPE, CERT_NAME_ISSUER_FLAG),
            thumbprint = get_cert_thumbprint(ctx, CERT_SHA1_HASH_PROP_ID),
            sha256     = get_cert_thumbprint(ctx, CERT_SHA256_HASH_PROP_ID),
        }
        prev = ctx
    end
    return certs
end

local function query_signed_message(path)
    local wpath = W.ToWide(path)
    local store_h = ffi.new("HCERTSTORE[1]")
    local msg_h   = ffi.new("HCRYPTMSG[1]")
    local enc_t   = ffi.new("DWORD[1]")
    local cont_t  = ffi.new("DWORD[1]")
    local fmt_t   = ffi.new("DWORD[1]")
    local ok = C.CryptQueryObject(
        CERT_QUERY_OBJECT_FILE,
        wpath,
        CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
        CERT_QUERY_FORMAT_FLAG_BINARY,
        0, enc_t, cont_t, fmt_t,
        store_h, msg_h, nil)
    if ok == 0 then return nil, tonumber(C.GetLastError()) end
    return { store = store_h[0], msg = msg_h[0] }
end

local function close_signed_message(q)
    if q.msg   ~= nil then C.CryptMsgClose(q.msg) end
    if q.store ~= nil then C.CertCloseStore(q.store, 0) end
end

-- Pull signer name + first cert thumbprint out of the embedded PKCS7.
local function read_signer(q)
    -- Allocate a CMSG_SIGNER_INFO_PARAM buffer.
    local cb = ffi.new("DWORD[1]")
    if C.CryptMsgGetParam(q.msg, CMSG_SIGNER_INFO_PARAM, 0, nil, cb) == 0 then
        return nil
    end
    local buf = ffi.new("uint8_t[?]", cb[0])
    if C.CryptMsgGetParam(q.msg, CMSG_SIGNER_INFO_PARAM, 0, buf, cb) == 0 then
        return nil
    end
    -- The CMSG_SIGNER_INFO has Issuer + SerialNumber blobs at known offsets,
    -- but parsing ASN.1 by hand is fragile. Instead, find the signer cert in
    -- the store by enumerating and picking the leaf (first non-CA).
    local certs = enum_store_certs(q.store)
    -- The leaf is conventionally first; fall back to certs[1].
    return certs, certs[1]
end

-- ===== verify ==========================================================

function M.verify(path, opts)
    opts = opts or {}
    local wd, _fi, _wpath = build_file_wvt(path, opts)
    local status = tonumber(C.WinVerifyTrust(nil, M.GENERIC_VERIFY_V2, wd))
    close_wvt(wd)

    local raw_status = status
    -- LONG is signed -> normalize to unsigned for HRESULT comparisons.
    if raw_status < 0 then raw_status = raw_status + 0x100000000 end

    local result = {
        valid        = (status == 0),
        trust_status = string.format("0x%08X", raw_status),
        path         = path,
        signer_name  = nil,
        signer_thumbprint = nil,
        certificates = {},
    }

    if raw_status == TRUST_E_NOSIGNATURE then
        result.error = "no signature"
        return result
    end

    -- Pull cert / signer metadata regardless of trust verdict so callers
    -- can decide what to do with weak / expired signatures.
    local q, qerr = query_signed_message(path)
    if not q then
        if not result.error then
            result.error = string.format("CryptQueryObject GLE=%d", qerr or 0)
        end
        return result
    end

    local certs, leaf = read_signer(q)
    result.certificates = certs or {}
    if leaf then
        result.signer_name       = leaf.subject
        result.signer_thumbprint = leaf.thumbprint
        result.subject           = leaf.subject
        result.issuer            = leaf.issuer
    end
    close_signed_message(q)

    if not result.valid then
        if raw_status == CERT_E_EXPIRED then result.error = "certificate expired"
        elseif raw_status == TRUST_E_BAD_DIGEST then result.error = "bad digest"
        else result.error = string.format("trust verdict 0x%08X", raw_status) end
    end
    return result
end

function M.is_signed(path)
    local q = query_signed_message(path)
    if not q then return false end
    -- Signed-message present is sufficient for "has a signature attached".
    -- Use verify() for the trust verdict.
    close_signed_message(q)
    return true
end

function M.signer_info(path)
    local r = M.verify(path)
    return {
        signer       = r.signer_name,
        thumbprint   = r.signer_thumbprint,
        issuer       = r.issuer,
        valid        = r.valid,
        trust_status = r.trust_status,
    }
end

-- ===== file hash (via BCryptHash, default SHA-256) =====================

local function open_alg(algo)
    -- algo: "SHA1" | "SHA256" | "SHA384" | "SHA512" | "MD5"
    local n = #algo
    local w = ffi.new("unsigned short[?]", n + 1)
    for i = 1, n do w[i - 1] = string.byte(algo, i) end
    w[n] = 0
    local h = ffi.new("PVOID[1]")
    local status = C.BCryptOpenAlgorithmProvider(h, w, nil, 0)
    if status ~= 0 then
        error(string.format("wintrust.file_hash: BCryptOpenAlgorithmProvider(%s) failed 0x%08X",
            algo, status % 0x100000000))
    end
    return h[0]
end

local _HASH_LEN = { SHA1 = 20, SHA256 = 32, SHA384 = 48, SHA512 = 64, MD5 = 16 }

function M.file_hash(path, algo)
    algo = (algo or "SHA256"):upper()
    local out_len = _HASH_LEN[algo]
    if not out_len then error("wintrust.file_hash: unsupported algo " .. algo) end

    -- Read the file via CreateFileW / ReadFile in chunks. For Authenticode-
    -- conformant hashing (skipping the Cert dir, optional header checksum,
    -- and security directory), callers should use CryptCATAdminCalcHashFromFileHandle.
    -- file_hash here is a plain file digest for use with cat_lookup_by_hash.
    local wpath = W.ToWide(path)
    local h = C.CreateFileW(wpath, W.GENERIC_READ, W.FILE_SHARE_READ, nil,
                            W.OPEN_EXISTING, W.FILE_ATTRIBUTE_NORMAL, nil)
    if h == W.INVALID_HANDLE_VALUE then
        error(string.format("wintrust.file_hash: CreateFileW(%s) GLE=%d",
            path, tonumber(C.GetLastError())))
    end

    -- BCryptHash is one-shot -- buffer the entire file. Reasonable for the
    -- catalog-hash flow (PE binaries -> few MB). For huge files, a streaming
    -- BCryptCreateHash / BCryptHashData loop would be needed.
    local CHUNK = 64 * 1024
    local parts = {}
    local buf = ffi.new("uint8_t[?]", CHUNK)
    local got = ffi.new("DWORD[1]")
    while true do
        if C.ReadFile(h, buf, CHUNK, got, nil) == 0 then
            C.CloseHandle(h)
            error("wintrust.file_hash: ReadFile GLE=" .. tonumber(C.GetLastError()))
        end
        if got[0] == 0 then break end
        parts[#parts + 1] = ffi.string(buf, tonumber(got[0]))
    end
    C.CloseHandle(h)

    local data = table.concat(parts)
    local alg = open_alg(algo)
    local in_buf = ffi.new("uint8_t[?]", math.max(1, #data))
    if #data > 0 then ffi.copy(in_buf, data, #data) end
    local out_buf = ffi.new("uint8_t[?]", out_len)
    local status = C.BCryptHash(alg, nil, 0, in_buf, #data, out_buf, out_len)
    C.BCryptCloseAlgorithmProvider(alg, 0)
    if status ~= 0 then
        error(string.format("wintrust.file_hash: BCryptHash failed 0x%08X", status % 0x100000000))
    end
    return ffi.string(out_buf, out_len)
end

-- ===== catalog lookup ==================================================
--
-- Authenticode-style file hash is computed by CryptCATAdminCalcHashFromFileHandle.
-- We expose both that primitive (for catalog lookups) and a generic file
-- digest helper (file_hash above).

local function authenticode_hash(path)
    local wpath = W.ToWide(path)
    local h = C.CreateFileW(wpath, W.GENERIC_READ, W.FILE_SHARE_READ, nil,
                            W.OPEN_EXISTING, W.FILE_ATTRIBUTE_NORMAL, nil)
    if h == W.INVALID_HANDLE_VALUE then
        return nil, "CreateFileW GLE=" .. tonumber(C.GetLastError())
    end
    local cb = ffi.new("DWORD[1]")
    cb[0] = 0
    -- First call: size query (pbHash=nil) -- typical CNG dance.
    C.CryptCATAdminCalcHashFromFileHandle(h, cb, nil, 0)
    if cb[0] == 0 then cb[0] = 32 end  -- SHA-1 historically; assume <= 32
    local buf = ffi.new("uint8_t[?]", cb[0])
    local ok = C.CryptCATAdminCalcHashFromFileHandle(h, cb, buf, 0)
    C.CloseHandle(h)
    if ok == 0 then return nil, "CalcHashFromFileHandle GLE=" .. tonumber(C.GetLastError()) end
    return ffi.string(buf, tonumber(cb[0]))
end

function M.cat_lookup_by_hash(hash)
    local cat_admin = ffi.new("HCATADMIN[1]")
    if C.CryptCATAdminAcquireContext(cat_admin, nil, 0) == 0 then
        return nil, "CatAdminAcquireContext GLE=" .. tonumber(C.GetLastError())
    end
    local hash_buf = ffi.new("uint8_t[?]", #hash)
    ffi.copy(hash_buf, hash, #hash)

    local out = {}
    local prev = nil
    while true do
        local ci = C.CryptCATAdminEnumCatalogFromHash(cat_admin[0], hash_buf, #hash, 0,
            prev and ffi.new("HCATINFO[1]", prev) or nil)
        if ci == nil then break end
        local info = ffi.new("CATALOG_INFO_WT")
        info.cbStruct = ffi.sizeof("CATALOG_INFO_WT")
        if C.CryptCATCatalogInfoFromContext(ci, info, 0) ~= 0 then
            out[#out + 1] = W.FromWide(info.wszCatalogFile)
        end
        C.CryptCATAdminReleaseCatalogContext(cat_admin[0], ci, 0)
        prev = nil  -- single-shot enumeration; avoids double-free
        break
    end
    C.CryptCATAdminReleaseContext(cat_admin[0], 0)
    return out[1]
end

-- ===== get_signatures (embedded + catalog) =============================

function M.get_signatures(path)
    local out = {}
    -- 1. Embedded signature, if any.
    local v = M.verify(path)
    if v.signer_name or v.certificates and #v.certificates > 0 then
        v.kind = "embedded"
        out[#out + 1] = v
    end
    -- 2. Catalog-signed lookup.
    local hash = authenticode_hash(path)
    if hash then
        local cat = M.cat_lookup_by_hash(hash)
        if cat then
            local cv = M.verify_catalog(path, cat)
            cv.kind = "catalog"
            cv.catalog = cat
            out[#out + 1] = cv
        end
    end
    return out
end

-- ===== verify_catalog ==================================================

function M.verify_catalog(path, catalog_path)
    local wpath = W.ToWide(path)
    local wcat  = W.ToWide(catalog_path)
    local wtag  = W.ToWide(path:match("[^\\/]+$") or path)

    -- Compute the file's Authenticode hash up front -- WinVerifyTrust uses
    -- it for the catalog member match.
    local hash, herr = authenticode_hash(path)
    if not hash then
        return { valid = false, error = herr, path = path, catalog = catalog_path }
    end
    local hash_buf = ffi.new("uint8_t[?]", #hash)
    ffi.copy(hash_buf, hash, #hash)

    local ci = ffi.new("WINTRUST_CATALOG_INFO")
    ci.cbStruct = ffi.sizeof("WINTRUST_CATALOG_INFO")
    ci.dwCatalogVersion = 0
    ci.pcwszCatalogFilePath = wcat
    ci.pcwszMemberTag       = wtag
    ci.pcwszMemberFilePath  = wpath
    ci.hMemberFile          = nil
    ci.pbCalculatedFileHash = hash_buf
    ci.cbCalculatedFileHash = #hash

    local wd = ffi.new("WINTRUST_DATA")
    wd.cbStruct = ffi.sizeof("WINTRUST_DATA")
    wd.dwUIChoice = M.WTD_UI_NONE
    wd.fdwRevocationChecks = M.WTD_REVOKE_NONE
    wd.dwUnionChoice = M.WTD_CHOICE_CATALOG
    wd.pInfoUnion = ci
    wd.dwStateAction = M.WTD_STATEACTION_VERIFY
    wd.dwProvFlags = M.WTD_CACHE_ONLY_URL_RETRIEVAL + M.WTD_REVOCATION_CHECK_NONE

    local status = tonumber(C.WinVerifyTrust(nil, M.GENERIC_VERIFY_V2, wd))
    close_wvt(wd)
    local raw = status < 0 and (status + 0x100000000) or status
    return {
        valid        = (status == 0),
        trust_status = string.format("0x%08X", raw),
        path         = path,
        catalog      = catalog_path,
    }
end

return M
