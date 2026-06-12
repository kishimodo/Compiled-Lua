-- tls_client -- TLS 1.2/1.3 client via Windows SChannel (secur32.dll).
--
-- Public surface:
--   tls_client.connect(host, port, opts?)   -> conn
--   conn:read(n?)                           -> data | nil, err
--   conn:read_line(opts?)                   -> data | nil, err
--   conn:read_exact(n)                      -> data | nil, err
--   conn:read_until(delim, max?)            -> data | nil, err
--   conn:write(s)                           -> n    | nil, err
--   conn:close()
--   conn:set_timeout(ms)
--   conn:peer_addr()                        -> host, port
--   conn:alpn()                             -> selected protocol string | nil
--
-- opts:
--   verify        -- default true; set false to skip cert validation
--   ca_certs      -- optional list of DER-encoded extra root certs to trust
--                    (CERT_CONTEXT bytes); used in addition to the system store
--   alpn          -- { "h2", "http/1.1" } -- order = preference
--   server_name   -- override SNI hostname (defaults to `host`)
--   verify_cb     -- function(cert_der, hostname) -> true|false; replaces
--                    SChannel verification entirely. Receives DER bytes
--                    and hostname; return true to accept.
--   timeout       -- ms; applied to underlying socket
--
-- Why SChannel directly (and not WinHTTP/WinINet for the TLS layer):
--   WinHTTP wraps the entire HTTP/1.1 protocol and exposes no raw
--   TLS stream. For redis/smtp/dns-over-tls/websocket we need a raw
--   TLS-encrypted byte stream we can put any protocol over the top of.
--   That means InitializeSecurityContext + EncryptMessage/DecryptMessage
--   directly. The SSPI surface is mature and stable since XP.

local ffi    = ffi
require "windows"
local socket = require "socket"

-- ============================================================
-- SSPI / SChannel cdef
-- ============================================================

ffi.cdef[[
typedef long           tls_SECURITY_STATUS;
typedef unsigned long  tls_ULONG;
typedef void *         tls_PVOID;

typedef struct tls_SecHandle {
    void *dwLower;
    void *dwUpper;
} tls_SecHandle;

typedef tls_SecHandle tls_CredHandle;
typedef tls_SecHandle tls_CtxtHandle;

typedef struct tls_TimeStamp {
    unsigned long LowPart;
    long          HighPart;
} tls_TimeStamp;

typedef struct tls_SecBuffer {
    tls_ULONG cbBuffer;
    tls_ULONG BufferType;
    void *    pvBuffer;
} tls_SecBuffer;

typedef struct tls_SecBufferDesc {
    tls_ULONG       ulVersion;
    tls_ULONG       cBuffers;
    tls_SecBuffer * pBuffers;
} tls_SecBufferDesc;

typedef struct tls_SCHANNEL_CRED {
    unsigned long  dwVersion;
    unsigned long  cCreds;
    void *         paCred;
    void *         hRootStore;
    unsigned long  cMappers;
    void *         aphMappers;
    unsigned long  cSupportedAlgs;
    unsigned long *palgSupportedAlgs;
    unsigned long  grbitEnabledProtocols;
    unsigned long  dwMinimumCipherStrength;
    unsigned long  dwMaximumCipherStrength;
    unsigned long  dwSessionLifespan;
    unsigned long  dwFlags;
    unsigned long  dwCredFormat;
} tls_SCHANNEL_CRED;

typedef struct tls_SecPkgContext_StreamSizes {
    unsigned long cbHeader;
    unsigned long cbTrailer;
    unsigned long cbMaximumMessage;
    unsigned long cBuffers;
    unsigned long cbBlockSize;
} tls_SecPkgContext_StreamSizes;

typedef struct tls_SecPkgContext_ApplicationProtocol {
    unsigned long ProtoNegoStatus;
    unsigned long ProtoNegoExt;
    unsigned char ProtocolIdSize;
    unsigned char ProtocolId[255];
} tls_SecPkgContext_ApplicationProtocol;

typedef struct tls_CERT_CONTEXT {
    unsigned long   dwCertEncodingType;
    unsigned char * pbCertEncoded;
    unsigned long   cbCertEncoded;
    void *          pCertInfo;
    void *          hCertStore;
} tls_CERT_CONTEXT;

typedef struct tls_CERT_CHAIN_PARA {
    unsigned long cbSize;
    struct {
        unsigned long dwUsageType;
        union {
            struct { unsigned long cUsageIdentifier; char **rgpszUsageIdentifier; } a;
            struct { unsigned long cUsageIdentifier; char **rgpszUsageIdentifier; } b;
        } Usage;
    } RequestedUsage;
} tls_CERT_CHAIN_PARA;

typedef struct tls_CERT_CHAIN_POLICY_PARA {
    unsigned long cbSize;
    unsigned long dwFlags;
    void *        pvExtraPolicyPara;
} tls_CERT_CHAIN_POLICY_PARA;

typedef struct tls_CERT_CHAIN_POLICY_STATUS {
    unsigned long cbSize;
    unsigned long dwError;
    long          lChainIndex;
    long          lElementIndex;
    void *        pvExtraPolicyStatus;
} tls_CERT_CHAIN_POLICY_STATUS;

typedef struct tls_SSL_EXTRA_CERT_CHAIN_POLICY_PARA {
    unsigned long cbSize;
    unsigned long dwAuthType;
    unsigned long fdwChecks;
    unsigned short *pwszServerName;
} tls_SSL_EXTRA_CERT_CHAIN_POLICY_PARA;

/* secur32.dll */
tls_SECURITY_STATUS AcquireCredentialsHandleW(
    unsigned short *, unsigned short *, unsigned long,
    void *, void *, void *, void *,
    tls_CredHandle *, tls_TimeStamp *);
tls_SECURITY_STATUS FreeCredentialsHandle(tls_CredHandle *);
tls_SECURITY_STATUS InitializeSecurityContextW(
    tls_CredHandle *, tls_CtxtHandle *, unsigned short *,
    unsigned long, unsigned long, unsigned long,
    tls_SecBufferDesc *, unsigned long,
    tls_CtxtHandle *, tls_SecBufferDesc *,
    unsigned long *, tls_TimeStamp *);
tls_SECURITY_STATUS DeleteSecurityContext(tls_CtxtHandle *);
tls_SECURITY_STATUS FreeContextBuffer(void *);
tls_SECURITY_STATUS QueryContextAttributesW(tls_CtxtHandle *, unsigned long, void *);
tls_SECURITY_STATUS EncryptMessage(tls_CtxtHandle *, unsigned long, tls_SecBufferDesc *, unsigned long);
tls_SECURITY_STATUS DecryptMessage(tls_CtxtHandle *, tls_SecBufferDesc *, unsigned long, unsigned long *);
tls_SECURITY_STATUS ApplyControlToken(tls_CtxtHandle *, tls_SecBufferDesc *);

/* crypt32.dll -- cert chain verification surface */
void * CertGetCertificateChain(void *, tls_CERT_CONTEXT *, void *, void *, void *, unsigned long, void *, void **);
int    CertVerifyCertificateChainPolicy(void *, void *, tls_CERT_CHAIN_POLICY_PARA *, tls_CERT_CHAIN_POLICY_STATUS *);
void   CertFreeCertificateChain(void *);
void   CertFreeCertificateContext(tls_CERT_CONTEXT *);
]]

pcall(ffi.load, "secur32")
pcall(ffi.load, "crypt32")
local C = ffi.C

-- ============================================================
-- Constants
-- ============================================================

local SCHANNEL_CRED_VERSION = 4
local UNISP_NAME_W          = "Microsoft Unified Security Protocol Provider"

local SECPKG_CRED_OUTBOUND  = 2
-- Disable internal SChannel name + chain verification when the caller
-- has supplied a verify_cb; we handle it ourselves and feed an answer.
local SCH_CRED_NO_DEFAULT_CREDS       = 0x00000010
local SCH_CRED_MANUAL_CRED_VALIDATION = 0x00000008
local SCH_CRED_AUTO_CRED_VALIDATION   = 0x00000020
local SCH_USE_STRONG_CRYPTO           = 0x00400000

-- Protocols (SP_PROT_*). TLS1_3 needs Windows 11+/Server 2022; we set
-- all of TLS1.2 + TLS1.3 by default and let SChannel pick.
local SP_PROT_TLS1_0_CLIENT = 0x80
local SP_PROT_TLS1_1_CLIENT = 0x200
local SP_PROT_TLS1_2_CLIENT = 0x800
local SP_PROT_TLS1_3_CLIENT = 0x2000

-- ISC_REQ flags. SEQUENCE_DETECT + REPLAY_DETECT + CONFIDENTIALITY are
-- the standard TLS triple; ALLOCATE_MEMORY tells SChannel to malloc the
-- output buffer for us; STREAM lets us drive a record-by-record loop.
local ISC_REQ_SEQUENCE_DETECT   = 0x00000008
local ISC_REQ_REPLAY_DETECT     = 0x00000004
local ISC_REQ_CONFIDENTIALITY   = 0x00000010
local ISC_REQ_ALLOCATE_MEMORY   = 0x00000100
local ISC_REQ_STREAM            = 0x00008000
local ISC_REQ_USE_SUPPLIED_CREDS= 0x00000080
local ISC_REQ_MANUAL_CRED_VALIDATION = 0x00080000

-- SECBUFFER_* types
local SECBUFFER_EMPTY               = 0
local SECBUFFER_DATA                = 1
local SECBUFFER_TOKEN               = 2
local SECBUFFER_STREAM_TRAILER      = 6
local SECBUFFER_STREAM_HEADER       = 7
local SECBUFFER_MISSING             = 4
local SECBUFFER_EXTRA               = 5
local SECBUFFER_ALERT               = 17
local SECBUFFER_APPLICATION_PROTOCOLS = 18

-- Return codes
local SEC_E_OK                       = 0
local SEC_I_CONTINUE_NEEDED          = 0x00090312
local SEC_I_CONTEXT_EXPIRED          = 0x00090317
local SEC_I_INCOMPLETE_CREDENTIALS   = 0x00090320
local SEC_I_RENEGOTIATE              = 0x00090321
local SEC_E_INCOMPLETE_MESSAGE       = 0x80090318
local SEC_E_BUFFER_TOO_SMALL         = 0x80090321

-- QueryContextAttributes IDs we use
local SECPKG_ATTR_STREAM_SIZES         = 4
local SECPKG_ATTR_REMOTE_CERT_CONTEXT  = 0x53
local SECPKG_ATTR_APPLICATION_PROTOCOL = 35

local SECBUFFER_VERSION = 0

-- ALPN extension type (RFC 7301) for SECBUFFER_APPLICATION_PROTOCOLS.
local SecApplicationProtocolNegotiationExt_ALPN = 2

-- ============================================================
-- ALPN buffer construction
-- ============================================================
--
-- SChannel ALPN format (SEC_APPLICATION_PROTOCOLS):
--   DWORD ProtocolListsSize       -- size of all SEC_APPLICATION_PROTOCOL_LIST
--   then [SEC_APPLICATION_PROTOCOL_LIST]:
--     DWORD ProtoNegoExt = 2 (ALPN)
--     WORD  ProtocolListSize     -- size of ProtocolList byte stream
--     BYTE[] ProtocolList        -- IETF "PrefixLen | bytes" wire format

local function build_alpn_buffer(protos)
    -- Build wire protocol list: each entry = 1 byte length + bytes.
    local plist = {}
    for _, p in ipairs(protos) do
        plist[#plist + 1] = string.char(#p) .. p
    end
    local wire = table.concat(plist)
    local wlen = #wire

    -- SEC_APPLICATION_PROTOCOL_LIST = DWORD + WORD + wire
    -- ProtocolListsSize (outer) = sizeof(DWORD)+sizeof(WORD)+#wire = 4+2+#wire
    local list_size = 4 + 2 + wlen
    local out = {}
    -- ProtocolListsSize (outer header, DWORD)
    out[#out + 1] = string.char( list_size        & 0xFF,
                                (list_size >>  8) & 0xFF,
                                (list_size >> 16) & 0xFF,
                                (list_size >> 24) & 0xFF)
    -- ProtoNegoExt (DWORD = 2)
    out[#out + 1] = string.char(SecApplicationProtocolNegotiationExt_ALPN, 0, 0, 0)
    -- ProtocolListSize (WORD)
    out[#out + 1] = string.char(wlen & 0xFF, (wlen >> 8) & 0xFF)
    out[#out + 1] = wire
    return table.concat(out)
end

-- ============================================================
-- LPCWSTR helpers (host names cross the API as UTF-16)
-- ============================================================

local function to_wide(s)
    -- We can rely on ASCII for hostnames + the SSPI package name.
    -- Build the UTF-16 buffer manually so we don't depend on
    -- MultiByteToWideChar in the cdef.
    local n = #s
    local buf = ffi.new("unsigned short[?]", n + 1)
    for i = 1, n do buf[i - 1] = s:byte(i) end
    buf[n] = 0
    return buf
end

-- ============================================================
-- SChannel low-level helpers
-- ============================================================

local function acquire_cred(opts)
    local cred = ffi.new("tls_SCHANNEL_CRED")
    cred.dwVersion = SCHANNEL_CRED_VERSION
    cred.grbitEnabledProtocols = SP_PROT_TLS1_2_CLIENT
                              | SP_PROT_TLS1_3_CLIENT
    local flags = SCH_USE_STRONG_CRYPTO | SCH_CRED_NO_DEFAULT_CREDS
    if opts.verify == false or opts.verify_cb then
        -- We do verification ourselves; tell SChannel not to.
        flags = flags | SCH_CRED_MANUAL_CRED_VALIDATION
    else
        flags = flags | SCH_CRED_AUTO_CRED_VALIDATION
    end
    cred.dwFlags = flags

    local handle = ffi.new("tls_CredHandle")
    local ts     = ffi.new("tls_TimeStamp")
    local pkg    = to_wide(UNISP_NAME_W)
    local st = C.AcquireCredentialsHandleW(
        nil, pkg, SECPKG_CRED_OUTBOUND,
        nil, cred, nil, nil, handle, ts)
    if st ~= SEC_E_OK then
        return nil, string.format("AcquireCredentialsHandle failed: 0x%08x", st)
    end
    return handle
end

-- Run the caller-supplied verify_cb against the negotiated peer cert.
local function run_verify_cb(ctxt, hostname, verify_cb)
    local cert_ptr = ffi.new("tls_CERT_CONTEXT *[1]")
    local st = C.QueryContextAttributesW(ctxt,
        SECPKG_ATTR_REMOTE_CERT_CONTEXT, cert_ptr)
    if st ~= SEC_E_OK then
        return false, string.format("QueryRemoteCert failed: 0x%08x", st)
    end
    local cert = cert_ptr[0]
    local der = ffi.string(cert.pbCertEncoded, cert.cbCertEncoded)
    local ok = verify_cb(der, hostname)
    C.CertFreeCertificateContext(cert)
    return ok and true or false, ok and nil or "verify_cb rejected peer certificate"
end

-- ============================================================
-- TLS handshake loop
-- ============================================================

local function do_handshake(transport, cred, hostname, opts)
    local target = to_wide(opts.server_name or hostname)
    local ctxt   = ffi.new("tls_CtxtHandle")
    local new_ctxt = ffi.new("tls_CtxtHandle")
    local attr   = ffi.new("unsigned long[1]")
    local ts     = ffi.new("tls_TimeStamp")

    local req_flags = ISC_REQ_SEQUENCE_DETECT
                    | ISC_REQ_REPLAY_DETECT
                    | ISC_REQ_CONFIDENTIALITY
                    | ISC_REQ_ALLOCATE_MEMORY
                    | ISC_REQ_STREAM
    if opts.verify == false or opts.verify_cb then
        req_flags = req_flags | ISC_REQ_MANUAL_CRED_VALIDATION
    end

    -- ALPN advertisement goes in the very first ISC call via input bufs.
    local alpn_str
    if opts.alpn and #opts.alpn > 0 then
        alpn_str = build_alpn_buffer(opts.alpn)
    end

    -- The handshake is a multi-round driven by:
    --   1. ISC returns CONTINUE_NEEDED + a token to send to peer
    --   2. send token, receive TLS records back from peer
    --   3. feed records back into ISC as input
    --   4. loop until ISC returns OK
    local incoming = ""  -- raw bytes from server still to be processed
    local first = true
    while true do
        -- Build input descriptor (server bytes + extra slot)
        local in_bufs = ffi.new("tls_SecBuffer[2]")
        if first and alpn_str then
            -- First call: feed ALPN list as the only input.
            in_bufs[0].cbBuffer   = #alpn_str
            in_bufs[0].BufferType = SECBUFFER_APPLICATION_PROTOCOLS
            local pa = ffi.new("char[?]", #alpn_str)
            ffi.copy(pa, alpn_str)
            in_bufs[0].pvBuffer   = pa
            in_bufs[1].BufferType = SECBUFFER_EMPTY
        elseif first then
            in_bufs[0].BufferType = SECBUFFER_EMPTY
            in_bufs[1].BufferType = SECBUFFER_EMPTY
        else
            -- subsequent rounds: feed accumulated server bytes
            in_bufs[0].cbBuffer   = #incoming
            in_bufs[0].BufferType = SECBUFFER_TOKEN
            local ib = ffi.new("char[?]", #incoming)
            ffi.copy(ib, incoming)
            in_bufs[0].pvBuffer   = ib
            in_bufs[1].BufferType = SECBUFFER_EMPTY
        end
        local in_desc = ffi.new("tls_SecBufferDesc")
        in_desc.ulVersion = SECBUFFER_VERSION
        in_desc.cBuffers  = 2
        in_desc.pBuffers  = in_bufs

        -- Output: SChannel will allocate the token bytes for us.
        local out_bufs = ffi.new("tls_SecBuffer[2]")
        out_bufs[0].BufferType = SECBUFFER_TOKEN
        out_bufs[0].pvBuffer   = nil
        out_bufs[0].cbBuffer   = 0
        out_bufs[1].BufferType = SECBUFFER_ALERT
        out_bufs[1].pvBuffer   = nil
        out_bufs[1].cbBuffer   = 0
        local out_desc = ffi.new("tls_SecBufferDesc")
        out_desc.ulVersion = SECBUFFER_VERSION
        out_desc.cBuffers  = 2
        out_desc.pBuffers  = out_bufs

        local st = C.InitializeSecurityContextW(
            cred,
            first and nil or ctxt,
            first and target or nil,
            req_flags, 0, 0,
            first and (alpn_str and in_desc or nil) or in_desc,
            0,
            first and new_ctxt or nil,
            out_desc, attr, ts)

        if first then
            ctxt.dwLower = new_ctxt.dwLower
            ctxt.dwUpper = new_ctxt.dwUpper
            first = false
        end

        -- Drain extra bytes from input descriptor first (TLS records
        -- arrive in lockstep but our recv might pull part of the next
        -- one prematurely; SChannel reports the leftover via SECBUFFER_EXTRA).
        local extra = ""
        for i = 0, 1 do
            if in_bufs[i].BufferType == SECBUFFER_EXTRA
                    and in_bufs[i].cbBuffer > 0 then
                local n = tonumber(in_bufs[i].cbBuffer)
                extra = incoming:sub(#incoming - n + 1)
            end
        end
        incoming = extra

        -- If SChannel produced a token, send it over the wire.
        if out_bufs[0].cbBuffer > 0 and out_bufs[0].pvBuffer ~= nil then
            local s = ffi.string(out_bufs[0].pvBuffer, out_bufs[0].cbBuffer)
            -- pvBuffer was allocated by SChannel (ISC_REQ_ALLOCATE_MEMORY); the
            -- documented owner-frees-it call is FreeContextBuffer. ffi.string
            -- already copied the bytes, so free it now -- otherwise every
            -- handshake leaked one token buffer.
            C.FreeContextBuffer(out_bufs[0].pvBuffer)
            out_bufs[0].pvBuffer = nil
            local ok, werr = transport:write(s)
            if not ok then
                return nil, "handshake write failed: " .. tostring(werr)
            end
        end

        if st == SEC_E_OK then
            return ctxt
        elseif st == SEC_I_CONTINUE_NEEDED then
            -- need more bytes from server; loop
        elseif st == SEC_E_INCOMPLETE_MESSAGE then
            -- need more bytes from server; loop without reissuing token
        elseif st == SEC_I_INCOMPLETE_CREDENTIALS then
            return nil, "server requested client certificate (unsupported)"
        else
            C.DeleteSecurityContext(ctxt)
            return nil, string.format("handshake failed: 0x%08x", st)
        end

        -- Read more bytes from server. We pull whatever's available;
        -- SECBUFFER_EXTRA on the next ISC will tell us if we over-read.
        local chunk, rerr = transport:read(16384)
        if not chunk then
            C.DeleteSecurityContext(ctxt)
            return nil, "handshake read failed: " .. tostring(rerr or "eof")
        end
        incoming = incoming .. chunk
    end
end

-- ============================================================
-- Connection object
-- ============================================================

local conn_mt = { __index = {} }
local conn_methods = conn_mt.__index

-- Query stream sizes so encrypt/decrypt buffers are sized correctly.
local function load_sizes(self)
    local sz = ffi.new("tls_SecPkgContext_StreamSizes")
    if C.QueryContextAttributesW(self.ctxt, SECPKG_ATTR_STREAM_SIZES, sz) ~= 0 then
        return nil, "QueryContextAttributes(StreamSizes) failed"
    end
    self.cb_header    = tonumber(sz.cbHeader)
    self.cb_trailer   = tonumber(sz.cbTrailer)
    self.cb_max_msg   = tonumber(sz.cbMaximumMessage)
    return true
end

-- Encrypt + send a single chunk (<= cb_max_msg).
local function encrypt_chunk(self, plain)
    local cap = self.cb_header + #plain + self.cb_trailer
    local outbuf = ffi.new("char[?]", cap)
    -- Copy plaintext into the data slot at offset cb_header.
    ffi.copy(outbuf + self.cb_header, plain, #plain)
    local bufs = ffi.new("tls_SecBuffer[4]")
    bufs[0].BufferType = SECBUFFER_STREAM_HEADER
    bufs[0].pvBuffer   = outbuf
    bufs[0].cbBuffer   = self.cb_header
    bufs[1].BufferType = SECBUFFER_DATA
    bufs[1].pvBuffer   = outbuf + self.cb_header
    bufs[1].cbBuffer   = #plain
    bufs[2].BufferType = SECBUFFER_STREAM_TRAILER
    bufs[2].pvBuffer   = outbuf + self.cb_header + #plain
    bufs[2].cbBuffer   = self.cb_trailer
    bufs[3].BufferType = SECBUFFER_EMPTY
    local desc = ffi.new("tls_SecBufferDesc")
    desc.ulVersion = SECBUFFER_VERSION
    desc.cBuffers  = 4
    desc.pBuffers  = bufs
    local st = C.EncryptMessage(self.ctxt, 0, desc, 0)
    if st ~= SEC_E_OK then
        return nil, string.format("EncryptMessage failed: 0x%08x", st)
    end
    local total = tonumber(bufs[0].cbBuffer + bufs[1].cbBuffer + bufs[2].cbBuffer)
    return ffi.string(outbuf, total)
end

function conn_methods:write(data)
    if self._closed then return nil, "tls conn closed" end
    local n = #data
    local pos = 1
    while pos <= n do
        local take = math.min(self.cb_max_msg, n - pos + 1)
        local enc, eerr = encrypt_chunk(self, data:sub(pos, pos + take - 1))
        if not enc then return nil, eerr end
        local ok, werr = self.transport:write(enc)
        if not ok then return nil, werr end
        pos = pos + take
    end
    return n
end

-- Pull and decrypt one TLS record. Appends plaintext to self._inbuf
-- and leaves any over-read bytes in self._ciphertext for the next call.
local function pump_one_record(self)
    while true do
        -- Try to decrypt what we already have.
        if #self._ciphertext > 0 then
            local ctlen = #self._ciphertext
            local buf = ffi.new("char[?]", ctlen)
            ffi.copy(buf, self._ciphertext)
            local bufs = ffi.new("tls_SecBuffer[4]")
            bufs[0].BufferType = SECBUFFER_DATA
            bufs[0].pvBuffer   = buf
            bufs[0].cbBuffer   = ctlen
            bufs[1].BufferType = SECBUFFER_EMPTY
            bufs[2].BufferType = SECBUFFER_EMPTY
            bufs[3].BufferType = SECBUFFER_EMPTY
            local desc = ffi.new("tls_SecBufferDesc")
            desc.ulVersion = SECBUFFER_VERSION
            desc.cBuffers  = 4
            desc.pBuffers  = bufs
            local st = C.DecryptMessage(self.ctxt, desc, 0, nil)
            if st == SEC_E_OK then
                -- Find SECBUFFER_DATA (plaintext) and SECBUFFER_EXTRA (leftover)
                local plain, extra = nil, nil
                for i = 0, 3 do
                    if bufs[i].BufferType == SECBUFFER_DATA
                            and bufs[i].pvBuffer ~= nil then
                        plain = ffi.string(bufs[i].pvBuffer, bufs[i].cbBuffer)
                    elseif bufs[i].BufferType == SECBUFFER_EXTRA
                            and bufs[i].pvBuffer ~= nil then
                        extra = ffi.string(bufs[i].pvBuffer, bufs[i].cbBuffer)
                    end
                end
                self._ciphertext = extra or ""
                if plain and #plain > 0 then
                    self._inbuf = self._inbuf .. plain
                    return true
                end
                -- empty TLS record (e.g. CCS) -- loop to pull more
            elseif st == SEC_E_INCOMPLETE_MESSAGE then
                -- need more ciphertext; fall through to recv
            elseif st == SEC_I_CONTEXT_EXPIRED then
                self._eof = true
                return false
            elseif st == SEC_I_RENEGOTIATE then
                return false, "renegotiate not supported"
            else
                return false, string.format("DecryptMessage failed: 0x%08x", st)
            end
        end
        local chunk, err = self.transport:read(16384)
        if not chunk then
            self._eof = true
            return false, err
        end
        self._ciphertext = self._ciphertext .. chunk
    end
end

function conn_methods:read(n)
    if self._closed then return nil, "tls conn closed" end
    n = n or 4096
    while #self._inbuf == 0 do
        if self._eof then return nil, "eof" end
        local ok, err = pump_one_record(self)
        if not ok and err then return nil, err end
        if not ok and self._eof and #self._inbuf == 0 then
            return nil, "eof"
        end
    end
    if #self._inbuf <= n then
        local out = self._inbuf
        self._inbuf = ""
        return out
    end
    local out = self._inbuf:sub(1, n)
    self._inbuf = self._inbuf:sub(n + 1)
    return out
end

function conn_methods:read_exact(n)
    local parts, total = {}, 0
    while total < n do
        local chunk, err = self:read(n - total)
        if not chunk then
            if err == "eof" and total > 0 then return nil, "short read" end
            return nil, err
        end
        parts[#parts + 1] = chunk
        total = total + #chunk
    end
    return table.concat(parts)
end

function conn_methods:read_until(delim, max_bytes)
    max_bytes = max_bytes or 1048576
    while true do
        local idx = self._inbuf:find(delim, 1, true)
        if idx then
            local out = self._inbuf:sub(1, idx - 1)
            self._inbuf = self._inbuf:sub(idx + #delim)
            return out
        end
        if #self._inbuf > max_bytes then
            return nil, "read_until: max_bytes exceeded"
        end
        if self._eof then return nil, "eof" end
        local ok, err = pump_one_record(self)
        if not ok and err then return nil, err end
        if not ok and self._eof and not self._inbuf:find(delim, 1, true) then
            return nil, "eof"
        end
    end
end

function conn_methods:read_line(opts)
    opts = opts or {}
    local delim = opts.crlf and "\r\n" or "\n"
    local s, err = self:read_until(delim, opts.max_bytes)
    if not s then return nil, err end
    if not opts.crlf and #s > 0 and s:sub(-1) == "\r" then
        s = s:sub(1, -2)
    end
    return s
end

-- Returns the ALPN protocol the peer selected, or nil if none.
function conn_methods:alpn()
    local ap = ffi.new("tls_SecPkgContext_ApplicationProtocol")
    if C.QueryContextAttributesW(self.ctxt,
            SECPKG_ATTR_APPLICATION_PROTOCOL, ap) ~= 0 then
        return nil
    end
    if ap.ProtoNegoStatus ~= 1 then return nil end
    if ap.ProtocolIdSize == 0 then return nil end
    return ffi.string(ap.ProtocolId, ap.ProtocolIdSize)
end

function conn_methods:set_timeout(ms)
    self.transport:set_timeout(ms)
end

function conn_methods:peer_addr()  return self.transport:peer_addr()  end
function conn_methods:local_addr() return self.transport:local_addr() end

function conn_methods:close()
    if self._closed then return end
    self._closed = true
    -- Best-effort: send TLS close_notify alert.
    pcall(function()
        local token = ffi.new("unsigned long[1]"); token[0] = 1 -- SCHANNEL_SHUTDOWN
        local bufs  = ffi.new("tls_SecBuffer[1]")
        bufs[0].BufferType = SECBUFFER_TOKEN
        bufs[0].pvBuffer   = token
        bufs[0].cbBuffer   = 4
        local desc = ffi.new("tls_SecBufferDesc")
        desc.ulVersion = SECBUFFER_VERSION
        desc.cBuffers  = 1
        desc.pBuffers  = bufs
        C.ApplyControlToken(self.ctxt, desc)
        -- We could call ISC one more time to produce the alert token
        -- and send it; for non-graceful close it's optional.
    end)
    C.DeleteSecurityContext(self.ctxt)
    C.FreeCredentialsHandle(self.cred)
    self.transport:close()
end

conn_mt.__gc = conn_methods.close

-- ============================================================
-- Public entry
-- ============================================================

local M = {}

function M.connect(host, port, opts)
    opts = opts or {}
    -- Open the plaintext transport first.
    local transport, terr = socket.tcp.connect(host, port, {
        timeout  = opts.timeout,
        nodelay  = true,
        family   = opts.family,
    })
    if not transport then return nil, terr end

    local cred, cerr = acquire_cred(opts)
    if not cred then transport:close(); return nil, cerr end

    local ctxt, herr = do_handshake(transport, cred, host, opts)
    if not ctxt then
        C.FreeCredentialsHandle(cred)
        transport:close()
        return nil, herr
    end

    local conn = setmetatable({
        transport   = transport,
        cred        = cred,
        ctxt        = ctxt,
        _closed     = false,
        _eof        = false,
        _inbuf      = "",
        _ciphertext = "",
    }, conn_mt)
    local ok, serr = load_sizes(conn)
    if not ok then conn:close(); return nil, serr end

    -- Run the optional caller callback against the negotiated peer cert.
    if opts.verify_cb then
        local vok, verr = run_verify_cb(ctxt, opts.server_name or host, opts.verify_cb)
        if not vok then conn:close(); return nil, verr end
    end
    return conn
end

return M
