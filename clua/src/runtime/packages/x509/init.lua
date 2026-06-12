-- x509 -- tolerant X.509 v3 certificate parser.
--
-- Public surface:
--   x509.parse_der(bytes) -> cert
--   x509.parse_pem(text)  -> cert  (accepts -----BEGIN CERTIFICATE----- blocks)
--   x509.oid_name(oid_string) -> "commonName" / "rsaEncryption" / ...
--
-- The returned cert is a table:
--   {
--     version            = 3,
--     serial             = "<hex>",
--     signature_algorithm = "sha256WithRSAEncryption",
--     issuer             = { { type="CN", value="..." }, ... },
--     subject            = { ... },
--     not_before         = <epoch seconds>,
--     not_after          = <epoch seconds>,
--     public_key = {
--         algorithm = "rsaEncryption" | "ecPublicKey",
--         rsa = { modulus=<bytes>, exponent=<int> }      -- if RSA
--         ec  = { curve="P-256", point=<bytes> }        -- if EC
--     },
--     extensions = {
--         san = { "example.com", "ip:1.2.3.4", ... },
--         key_usage = { "digitalSignature", ... },
--         extended_key_usage = { "serverAuth", ... },
--         basic_constraints = { ca=true, path_len=0 },
--         subject_key_id    = "<hex>",
--         authority_key_id  = "<hex>",
--         raw = { [oid] = { critical=bool, value=<bytes> }, ... },
--     },
--     signature = <bytes>,
--     tbs_der = <bytes>,   -- the to-be-signed portion (for signature verification)
--   }

-- We lazily require windows only for the Crypt32 backend's typedefs.
-- Pure-Lua parsing should not pay that cost; the require happens on the first
-- call to a Crypt32-backed entry (verify_chain / system_store).

local M = {}

-- ===== ASN.1 DER tag constants =========================================

local T_INTEGER       = 0x02
local T_BIT_STRING    = 0x03
local T_OCTET_STRING  = 0x04
local T_NULL          = 0x05
local T_OID           = 0x06
local T_UTF8STRING    = 0x0C
local T_PRINTABLE     = 0x13
local T_TELETEX       = 0x14
local T_IA5STRING     = 0x16
local T_UTCTIME       = 0x17
local T_GENTIME       = 0x18
local T_BMPSTRING     = 0x1E
local T_SEQUENCE      = 0x30
local T_SET           = 0x31

-- Context-specific tags (constructed): 0xA0 + n; primitive: 0x80 + n.

-- ===== ASN.1 reader ====================================================

local function read_len(s, i)
    local b = s:byte(i)
    if b < 0x80 then return b, i + 1 end
    local n = b & 0x7F
    if n == 0 then error("x509: indefinite-length encoding not allowed in DER") end
    if n > 4   then error("x509: length > 4 bytes not supported") end
    local len = 0
    for k = 1, n do len = (len << 8) | s:byte(i + k) end
    return len, i + 1 + n
end

local function read_tlv(s, i)
    -- Returns: tag, content_start, content_end, total_end
    if i > #s then error("x509: unexpected end of DER stream") end
    local tag = s:byte(i)
    local len, next_i = read_len(s, i + 1)
    local cstart = next_i
    local cend   = next_i + len - 1
    if cend > #s then error("x509: TLV runs past end of buffer") end
    return tag, cstart, cend, cend + 1
end

-- Iterate TLVs inside a constructed value.
local function children(s, start, finish)
    local i = start
    return function()
        if i > finish then return nil end
        local tag, cs, ce, ni = read_tlv(s, i)
        i = ni
        return tag, cs, ce
    end
end

-- ===== Integer / OID decoders ==========================================

local function read_integer(s, cs, ce)
    -- Returns a Lua number if it fits, otherwise raw bytes (for big ints like RSA modulus).
    local n = ce - cs + 1
    if n <= 8 then
        local first = s:byte(cs)
        local neg = (first & 0x80) ~= 0
        local v = 0
        for i = cs, ce do v = (v << 8) | s:byte(i) end
        if neg then v = v - (1 << (8 * n)) end
        return v
    end
    -- Strip leading zero (sign byte) for unsigned big ints.
    if s:byte(cs) == 0 and n > 1 then
        return s:sub(cs + 1, ce)
    end
    return s:sub(cs, ce)
end

local function read_oid(s, cs, ce)
    if cs > ce then return "" end
    local first = s:byte(cs)
    local parts = { tostring(first // 40), tostring(first % 40) }
    local i = cs + 1
    while i <= ce do
        local v = 0
        while true do
            local b = s:byte(i)
            i = i + 1
            v = (v << 7) | (b & 0x7F)
            if (b & 0x80) == 0 then break end
            if i > ce then error("x509: truncated OID") end
        end
        parts[#parts + 1] = tostring(v)
    end
    return table.concat(parts, ".")
end

-- ===== OID -> human name ===============================================

local OID_NAMES = {
    -- Hash + signature algorithms
    ["1.2.840.113549.1.1.1"]  = "rsaEncryption",
    ["1.2.840.113549.1.1.5"]  = "sha1WithRSAEncryption",
    ["1.2.840.113549.1.1.11"] = "sha256WithRSAEncryption",
    ["1.2.840.113549.1.1.12"] = "sha384WithRSAEncryption",
    ["1.2.840.113549.1.1.13"] = "sha512WithRSAEncryption",
    ["1.2.840.113549.1.1.10"] = "rsaSSA-PSS",
    ["1.2.840.10045.2.1"]     = "ecPublicKey",
    ["1.2.840.10045.4.3.2"]   = "ecdsa-with-SHA256",
    ["1.2.840.10045.4.3.3"]   = "ecdsa-with-SHA384",
    ["1.2.840.10045.4.3.4"]   = "ecdsa-with-SHA512",
    -- EC curves
    ["1.2.840.10045.3.1.7"]   = "P-256",
    ["1.3.132.0.34"]          = "P-384",
    ["1.3.132.0.35"]          = "P-521",
    -- DN attributes
    ["2.5.4.3"]   = "CN",
    ["2.5.4.6"]   = "C",
    ["2.5.4.7"]   = "L",
    ["2.5.4.8"]   = "ST",
    ["2.5.4.10"]  = "O",
    ["2.5.4.11"]  = "OU",
    ["2.5.4.5"]   = "serialNumber",
    ["2.5.4.4"]   = "SN",
    ["2.5.4.42"]  = "GN",
    ["1.2.840.113549.1.9.1"] = "emailAddress",
    ["0.9.2342.19200300.100.1.25"] = "DC",
    -- v3 extensions
    ["2.5.29.14"] = "subjectKeyIdentifier",
    ["2.5.29.15"] = "keyUsage",
    ["2.5.29.17"] = "subjectAltName",
    ["2.5.29.19"] = "basicConstraints",
    ["2.5.29.31"] = "cRLDistributionPoints",
    ["2.5.29.32"] = "certificatePolicies",
    ["2.5.29.35"] = "authorityKeyIdentifier",
    ["2.5.29.37"] = "extendedKeyUsage",
    -- EKU values
    ["1.3.6.1.5.5.7.3.1"] = "serverAuth",
    ["1.3.6.1.5.5.7.3.2"] = "clientAuth",
    ["1.3.6.1.5.5.7.3.3"] = "codeSigning",
    ["1.3.6.1.5.5.7.3.4"] = "emailProtection",
    ["1.3.6.1.5.5.7.3.8"] = "timeStamping",
    ["1.3.6.1.5.5.7.3.9"] = "OCSPSigning",
}

function M.oid_name(oid) return OID_NAMES[oid] or oid end

-- ===== DN parser =======================================================

local function parse_dn(s, start, finish)
    local rdns = {}
    for tag, cs, ce in children(s, start, finish) do
        if tag == T_SET then
            for atvtag, atvcs, atvce in children(s, cs, ce) do
                if atvtag ~= T_SEQUENCE then error("x509: bad DN ATV (not SEQUENCE)") end
                local seq_iter = children(s, atvcs, atvce)
                local otag, ocs, oce = seq_iter()
                if otag ~= T_OID then error("x509: DN ATV missing OID") end
                local oid = read_oid(s, ocs, oce)
                local vtag, vcs, vce = seq_iter()
                if vtag == nil then error("x509: DN ATV missing value") end
                local val
                if vtag == T_UTF8STRING or vtag == T_PRINTABLE
                   or vtag == T_IA5STRING or vtag == T_TELETEX then
                    val = s:sub(vcs, vce)
                elseif vtag == T_BMPSTRING then
                    -- BMP: UTF-16BE; decode to UTF-8.
                    local out, n = {}, 0
                    local i = vcs
                    while i + 1 <= vce do
                        local cp = (s:byte(i) << 8) | s:byte(i + 1)
                        if cp < 0x80 then
                            n = n + 1; out[n] = string.char(cp)
                        elseif cp < 0x800 then
                            n = n + 1; out[n] = string.char(0xC0 | (cp >> 6),
                                                            0x80 | (cp & 0x3F))
                        else
                            n = n + 1; out[n] = string.char(0xE0 | (cp >> 12),
                                                            0x80 | ((cp >> 6) & 0x3F),
                                                            0x80 | (cp & 0x3F))
                        end
                        i = i + 2
                    end
                    val = table.concat(out)
                else
                    val = s:sub(vcs, vce)
                end
                rdns[#rdns + 1] = { type = M.oid_name(oid), oid = oid, value = val }
            end
        end
    end
    return rdns
end

-- ===== Time parser =====================================================

local function parse_time(s, tag, cs, ce)
    -- UTCTime: YYMMDDHHMMSSZ. GeneralizedTime: YYYYMMDDHHMMSSZ (possibly with fractions).
    local str = s:sub(cs, ce)
    local y, mo, d, h, mi, se
    if tag == T_UTCTIME then
        y, mo, d, h, mi, se = str:match("^(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)Z$")
        if y == nil then return nil end
        y = tonumber(y)
        y = (y < 50) and (2000 + y) or (1900 + y)
    elseif tag == T_GENTIME then
        y, mo, d, h, mi, se = str:match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)Z?")
        if y == nil then return nil end
        y = tonumber(y)
    else
        return nil
    end
    -- os.time interprets its field table as LOCAL time, but X.509
    -- UTCTime/GeneralizedTime are UTC. Compute the host's local-vs-UTC offset
    -- (now_local_epoch - epoch_of(now_as_utc_fields)) and add it so the result
    -- is the true UTC epoch regardless of the host timezone.
    local now = os.time()
    local utc_offset = os.difftime(now, os.time(os.date("!*t", now)))
    return os.time({
        year = y, month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
        isdst = false,
    }) + utc_offset
end

-- ===== Public key parser ===============================================

local function parse_subject_public_key_info(s, start, finish)
    local iter = children(s, start, finish)
    local alg_tag, alg_cs, alg_ce = iter()
    if alg_tag ~= T_SEQUENCE then error("x509: SPKI missing algorithm SEQUENCE") end
    local key_tag, key_cs, key_ce = iter()
    if key_tag ~= T_BIT_STRING then error("x509: SPKI missing BIT STRING") end

    local alg_iter = children(s, alg_cs, alg_ce)
    local otag, ocs, oce = alg_iter()
    if otag ~= T_OID then error("x509: SPKI algorithm missing OID") end
    local alg_oid = read_oid(s, ocs, oce)
    local alg_name = M.oid_name(alg_oid)

    -- BIT STRING content: first byte is "unused bits" count; the rest is the key blob.
    if s:byte(key_cs) ~= 0 then
        error("x509: SPKI BIT STRING has unused bits != 0 (unsupported)")
    end
    local key_bytes = s:sub(key_cs + 1, key_ce)

    local pk = { algorithm = alg_name, algorithm_oid = alg_oid, raw = key_bytes }

    if alg_name == "rsaEncryption" then
        -- RSA: BIT STRING wraps a SEQUENCE { INTEGER modulus, INTEGER exponent }
        local r_tag, r_cs, r_ce = read_tlv(key_bytes, 1)
        if r_tag ~= T_SEQUENCE then error("x509: RSA pubkey not a SEQUENCE") end
        local rsa_iter = children(key_bytes, r_cs, r_ce)
        local m_tag, m_cs, m_ce = rsa_iter()
        local e_tag, e_cs, e_ce = rsa_iter()
        if m_tag ~= T_INTEGER or e_tag ~= T_INTEGER then
            error("x509: RSA pubkey malformed")
        end
        local mod = read_integer(key_bytes, m_cs, m_ce)
        local exp = read_integer(key_bytes, e_cs, e_ce)
        pk.rsa = { modulus = type(mod) == "string" and mod or string.char(mod),
                   exponent = type(exp) == "number" and exp or exp }
    elseif alg_name == "ecPublicKey" then
        -- ECC: algorithm parameters carry the curve OID; key is the EC point.
        local p_tag, p_cs, p_ce = alg_iter()
        local curve_oid
        if p_tag == T_OID then curve_oid = read_oid(s, p_cs, p_ce) end
        pk.ec = {
            curve     = curve_oid and M.oid_name(curve_oid) or nil,
            curve_oid = curve_oid,
            point     = key_bytes,
        }
    end
    return pk
end

-- ===== Extension parsers ===============================================

local function parse_san(value)
    local sans = {}
    -- SubjectAltName ::= SEQUENCE OF GeneralName
    local tag, cs, ce = read_tlv(value, 1)
    if tag ~= T_SEQUENCE then return sans end
    for gtag, gcs, gce in children(value, cs, ce) do
        local raw = value:sub(gcs, gce)
        local kind = gtag & 0x1F
        if kind == 2 then       -- dNSName
            sans[#sans + 1] = "dns:" .. raw
        elseif kind == 1 then   -- rfc822Name
            sans[#sans + 1] = "email:" .. raw
        elseif kind == 6 then   -- uniformResourceIdentifier
            sans[#sans + 1] = "uri:" .. raw
        elseif kind == 7 then   -- iPAddress
            if #raw == 4 then
                sans[#sans + 1] = string.format("ip:%d.%d.%d.%d",
                    raw:byte(1), raw:byte(2), raw:byte(3), raw:byte(4))
            else
                sans[#sans + 1] = "ip:" .. raw
            end
        else
            sans[#sans + 1] = string.format("other:%d:%s", kind, raw)
        end
    end
    return sans
end

local KEY_USAGE_BITS = {
    [1] = "digitalSignature",
    [2] = "nonRepudiation",
    [3] = "keyEncipherment",
    [4] = "dataEncipherment",
    [5] = "keyAgreement",
    [6] = "keyCertSign",
    [7] = "cRLSign",
    [8] = "encipherOnly",
    [9] = "decipherOnly",
}

local function parse_key_usage(value)
    local tag, cs, ce = read_tlv(value, 1)
    if tag ~= T_BIT_STRING then return {} end
    local unused = value:byte(cs)
    local bits = value:sub(cs + 1, ce)
    local out = {}
    local nbits = (#bits * 8) - unused
    local idx = 0
    for i = 1, #bits do
        local b = bits:byte(i)
        for shift = 7, 0, -1 do
            idx = idx + 1
            if idx <= nbits and ((b >> shift) & 1) == 1 then
                local name = KEY_USAGE_BITS[idx]
                if name then out[#out + 1] = name end
            end
        end
    end
    return out
end

local function parse_eku(value)
    local tag, cs, ce = read_tlv(value, 1)
    if tag ~= T_SEQUENCE then return {} end
    local out = {}
    for otag, ocs, oce in children(value, cs, ce) do
        if otag == T_OID then
            out[#out + 1] = M.oid_name(read_oid(value, ocs, oce))
        end
    end
    return out
end

local function parse_basic_constraints(value)
    local out = { ca = false }
    local tag, cs, ce = read_tlv(value, 1)
    if tag ~= T_SEQUENCE then return out end
    for ctag, ccs, cce in children(value, cs, ce) do
        if ctag == 0x01 then        -- BOOLEAN cA
            out.ca = value:byte(ccs) ~= 0
        elseif ctag == T_INTEGER then
            out.path_len = read_integer(value, ccs, cce)
        end
    end
    return out
end

local function hex_of(bytes)
    local t = {}
    for i = 1, #bytes do t[i] = string.format("%02x", bytes:byte(i)) end
    return table.concat(t)
end

local function parse_extensions(s, start, finish)
    -- v3 extensions := SEQUENCE OF SEQUENCE { OID, BOOLEAN? critical, OCTET STRING value }
    local ext = { raw = {} }
    -- The outer context-specific tag wraps a SEQUENCE.
    local tag, cs, ce = read_tlv(s, start)
    if tag ~= T_SEQUENCE then return ext end
    for etag, ecs, ece in children(s, cs, ce) do
        if etag == T_SEQUENCE then
            local iter = children(s, ecs, ece)
            local otag, ocs, oce = iter()
            local oid = read_oid(s, ocs, oce)
            local critical = false
            local nxt_t, nxt_cs, nxt_ce = iter()
            if nxt_t == 0x01 then  -- BOOLEAN critical
                critical = s:byte(nxt_cs) ~= 0
                nxt_t, nxt_cs, nxt_ce = iter()
            end
            if nxt_t ~= T_OCTET_STRING then
                -- malformed -- skip silently
            else
                local value = s:sub(nxt_cs, nxt_ce)
                ext.raw[oid] = { critical = critical, value = value, name = M.oid_name(oid) }
                local name = M.oid_name(oid)
                if name == "subjectAltName" then
                    ext.san = parse_san(value)
                elseif name == "keyUsage" then
                    ext.key_usage = parse_key_usage(value)
                elseif name == "extendedKeyUsage" then
                    ext.extended_key_usage = parse_eku(value)
                elseif name == "basicConstraints" then
                    ext.basic_constraints = parse_basic_constraints(value)
                elseif name == "subjectKeyIdentifier" then
                    local ttag, tcs, tce = read_tlv(value, 1)
                    if ttag == T_OCTET_STRING then
                        ext.subject_key_id = hex_of(value:sub(tcs, tce))
                    end
                elseif name == "authorityKeyIdentifier" then
                    local ttag, tcs, tce = read_tlv(value, 1)
                    if ttag == T_SEQUENCE then
                        for atag, acs, ace in children(value, tcs, tce) do
                            if (atag & 0x1F) == 0 then
                                ext.authority_key_id = hex_of(value:sub(acs, ace))
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    return ext
end

-- ===== Top-level Certificate parser ====================================

function M.parse_der(der)
    if type(der) ~= "string" then error("x509.parse_der: expected string") end
    -- Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature BIT STRING }
    local top_tag, top_cs, top_ce = read_tlv(der, 1)
    if top_tag ~= T_SEQUENCE then error("x509: top-level not a SEQUENCE") end
    local outer = children(der, top_cs, top_ce)
    local tbs_tag, tbs_cs, tbs_ce = outer()
    if tbs_tag ~= T_SEQUENCE then error("x509: tbsCertificate not a SEQUENCE") end
    -- The full TBS slice (including its TLV header) is the to-be-signed span,
    -- usable for verifying the outer signature against the cert's contents.
    local tbs_der = der:sub(top_cs, tbs_ce)

    local sig_alg_tag, sig_alg_cs, sig_alg_ce = outer()
    if sig_alg_tag ~= T_SEQUENCE then error("x509: signatureAlgorithm not a SEQUENCE") end
    local sig_tag, sig_cs, sig_ce = outer()
    if sig_tag ~= T_BIT_STRING then error("x509: signature not a BIT STRING") end

    -- Read signatureAlgorithm OID
    local sa_iter = children(der, sig_alg_cs, sig_alg_ce)
    local satag, sacs, sace = sa_iter()
    if satag ~= T_OID then error("x509: signatureAlgorithm missing OID") end
    local sig_alg_oid  = read_oid(der, sacs, sace)
    local sig_alg_name = M.oid_name(sig_alg_oid)

    -- Strip BIT STRING unused-bits prefix
    if der:byte(sig_cs) ~= 0 then
        error("x509: signature BIT STRING with unused bits != 0")
    end
    local signature = der:sub(sig_cs + 1, sig_ce)

    -- Walk the TBS body.
    local tbs_iter = children(der, tbs_cs, tbs_ce)
    local tag, cs, ce = tbs_iter()
    local version = 1
    if tag == 0xA0 then  -- [0] EXPLICIT version
        local vt, vcs, vce = read_tlv(der, cs)
        if vt == T_INTEGER then version = read_integer(der, vcs, vce) + 1 end
        tag, cs, ce = tbs_iter()
    end

    -- serialNumber INTEGER
    if tag ~= T_INTEGER then error("x509: missing serialNumber") end
    local serial_bytes = der:sub(cs, ce)
    local serial_hex   = hex_of(serial_bytes)

    -- signature (algorithm identifier inside TBS, must match outer)
    tag, cs, ce = tbs_iter()
    if tag ~= T_SEQUENCE then error("x509: tbs missing inner signatureAlgorithm") end

    -- issuer
    tag, cs, ce = tbs_iter()
    if tag ~= T_SEQUENCE then error("x509: tbs missing issuer") end
    local issuer = parse_dn(der, cs, ce)

    -- validity
    tag, cs, ce = tbs_iter()
    if tag ~= T_SEQUENCE then error("x509: tbs missing validity") end
    local val_iter = children(der, cs, ce)
    local nb_t, nb_cs, nb_ce = val_iter()
    local na_t, na_cs, na_ce = val_iter()
    local not_before = parse_time(der, nb_t, nb_cs, nb_ce)
    local not_after  = parse_time(der, na_t, na_cs, na_ce)

    -- subject
    tag, cs, ce = tbs_iter()
    if tag ~= T_SEQUENCE then error("x509: tbs missing subject") end
    local subject = parse_dn(der, cs, ce)

    -- SPKI
    tag, cs, ce = tbs_iter()
    if tag ~= T_SEQUENCE then error("x509: tbs missing subjectPublicKeyInfo") end
    local public_key = parse_subject_public_key_info(der, cs, ce)

    -- Optional [1]/[2] issuerUniqueID/subjectUniqueID, then [3] extensions
    local extensions = { raw = {} }
    tag, cs, ce = tbs_iter()
    while tag ~= nil do
        -- [3] EXPLICIT extensions wraps a SEQUENCE; parse_extensions reads
        -- the inner SEQUENCE TLV starting at cs.
        if tag == 0xA3 then
            extensions = parse_extensions(der, cs, ce)
        end
        tag, cs, ce = tbs_iter()
    end

    return {
        version             = version,
        serial              = serial_hex,
        serial_bytes        = serial_bytes,
        signature_algorithm = sig_alg_name,
        signature_algorithm_oid = sig_alg_oid,
        issuer              = issuer,
        subject             = subject,
        not_before          = not_before,
        not_after           = not_after,
        public_key          = public_key,
        extensions          = extensions,
        signature           = signature,
        tbs_der             = tbs_der,
    }
end

-- ===== PEM ============================================================

local function decode_base64(body)
    -- Inline base64 decoder (avoid a hard package dep just for this).
    local dec = {}
    local alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do dec[alpha:byte(i)] = i - 1 end
    local out, n = {}, 0
    local accum, bits = 0, 0
    for i = 1, #body do
        local b = body:byte(i)
        if b == 61 then break end  -- '='
        local v = dec[b]
        if v == nil then error("x509: invalid base64 character") end
        accum = (accum << 6) | v
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            n = n + 1; out[n] = string.char((accum >> bits) & 0xFF)
            accum = accum & ((1 << bits) - 1)
        end
    end
    return table.concat(out)
end

local function encode_base64(bytes, line_len)
    local alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out, n = {}, 0
    local len = #bytes
    local i = 1
    while i + 2 <= len do
        local b1, b2, b3 = bytes:byte(i, i + 2)
        local v = b1 * 65536 + b2 * 256 + b3
        local a, b, c, d = ((v >> 18) & 0x3F) + 1, ((v >> 12) & 0x3F) + 1,
                           ((v >>  6) & 0x3F) + 1, ( v        & 0x3F) + 1
        n = n + 1; out[n] = alpha:sub(a, a)
        n = n + 1; out[n] = alpha:sub(b, b)
        n = n + 1; out[n] = alpha:sub(c, c)
        n = n + 1; out[n] = alpha:sub(d, d)
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local b1 = bytes:byte(i)
        local v = b1 * 65536
        local a, b = ((v >> 18) & 0x3F) + 1, ((v >> 12) & 0x3F) + 1
        n = n + 1; out[n] = alpha:sub(a, a)
        n = n + 1; out[n] = alpha:sub(b, b)
        n = n + 1; out[n] = "=="
    elseif rem == 2 then
        local b1, b2 = bytes:byte(i, i + 1)
        local v = b1 * 65536 + b2 * 256
        local a, b, c = ((v >> 18) & 0x3F) + 1, ((v >> 12) & 0x3F) + 1,
                        ((v >>  6) & 0x3F) + 1
        n = n + 1; out[n] = alpha:sub(a, a)
        n = n + 1; out[n] = alpha:sub(b, b)
        n = n + 1; out[n] = alpha:sub(c, c)
        n = n + 1; out[n] = "="
    end
    local b64 = table.concat(out)
    if line_len and line_len > 0 then
        local wrapped, p = {}, 1
        while p <= #b64 do
            wrapped[#wrapped + 1] = b64:sub(p, p + line_len - 1)
            p = p + line_len
        end
        return table.concat(wrapped, "\n")
    end
    return b64
end

function M.parse_pem(text)
    if type(text) ~= "string" then error("x509.parse_pem: expected string") end
    local body = text:match("%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-(.-)%-%-%-%-%-END CERTIFICATE%-%-%-%-%-")
    if body == nil then
        error("x509.parse_pem: no CERTIFICATE block found")
    end
    body = body:gsub("[%s\r\n]", "")
    return M.parse_der(decode_base64(body))
end

-- Top-level entry: accept either form transparently.
function M.parse(input)
    if type(input) ~= "string" then error("x509.parse: expected string") end
    if input:find("BEGIN CERTIFICATE", 1, true) then
        return M.parse_pem(input)
    end
    return M.parse_der(input)
end

-- ===== Hostname / identity matching (RFC 6125) =========================
--
-- verify_chain() establishes that a certificate chains to a trusted root, but
-- it does NOT check that the certificate was ISSUED FOR the host you are
-- talking to -- a valid cert for evil.com would otherwise be accepted when
-- presented for example.com. match_hostname() closes that gap: callers run it
-- AFTER a successful verify_chain to bind the verified cert to the expected
-- name.

-- Match one DNS name pattern (optionally a leftmost-label wildcard) against a
-- host, per RFC 6125: case-insensitive; a `*` is allowed only as the ENTIRE
-- leftmost label and matches exactly one label (no embedded dots); the portion
-- after the wildcard must itself contain a dot (so `*.com` is rejected).
local function dns_name_matches(pattern, host)
    pattern = pattern:gsub("%.$", ""):lower()
    host    = host:gsub("%.$", ""):lower()
    if pattern == "" or host == "" then return false end
    if pattern == host then return true end
    local rest = pattern:match("^%*%.(.+)$")        -- wildcard only in label 1
    if not rest then return false end
    if not rest:find(".", 1, true) then return false end    -- reject *.com etc. (need an embedded dot)
    local _, hrest = host:match("^([^.]+)%.(.+)$")  -- host must have a leading label
    return hrest ~= nil and hrest == rest
end

-- Does `cert` (from M.parse/parse_der) identify `hostname`? Checks dNSName SANs
-- (with wildcards), iPAddress SANs for an IP literal, and -- ONLY when the cert
-- carries no dNSName SAN at all -- the subject CN (RFC 6125 deprecates the CN
-- fallback, and clients ignore it when any DNS SAN is present). Returns a
-- boolean; never throws on a well-formed parsed cert.
function M.match_hostname(cert, hostname)
    if type(cert) ~= "table" or type(hostname) ~= "string" or hostname == "" then
        return false
    end
    local host  = hostname:gsub("%.$", ""):lower()
    local is_ip = host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
    local san   = cert.extensions and cert.extensions.san
    local saw_dns = false
    if san then
        for _, entry in ipairs(san) do
            local kind, val = entry:match("^(%a+):(.*)$")
            if kind == "dns" then
                saw_dns = true
                if not is_ip and dns_name_matches(val, host) then return true end
            elseif kind == "ip" then
                if is_ip and val:lower() == host then return true end
            end
        end
    end
    -- CN fallback only when there was no dNSName SAN, and never for IP literals.
    if not saw_dns and not is_ip and type(cert.subject) == "table" then
        for _, rdn in ipairs(cert.subject) do
            if rdn.type == "CN" and dns_name_matches(rdn.value, host) then return true end
        end
    end
    return false
end

-- Re-encode a DER blob (or a parsed cert that retains its raw bytes) as PEM.
local function cert_to_pem(self_or_der)
    local der
    if type(self_or_der) == "string" then
        der = self_or_der
    elseif type(self_or_der) == "table" and type(self_or_der.der) == "string" then
        der = self_or_der.der
    else
        error("x509.to_pem: need DER bytes or a parsed cert with .der")
    end
    return "-----BEGIN CERTIFICATE-----\n"
        .. encode_base64(der, 64)
        .. "\n-----END CERTIFICATE-----\n"
end

M.to_pem = cert_to_pem

-- ===== Windows Crypt32 backend (cert validation + store enumeration) ==

local _crypt32_loaded = false
local function load_crypt32()
    if _crypt32_loaded then return true end
    -- The Crypt32 cdef block references HANDLE, BOOL, LPCSTR, FILETIME -- all
    -- declared by the base 'windows' package. Pull it in lazily so pure-Lua
    -- DER parsing pays nothing.
    pcall(require, "windows")
    -- ffi binding for the subset we need. Wrapped in pcall so the package
    -- still imports on hosts where crypt32 isn't available.
    local ok = pcall(function()
        ffi.cdef[[
        typedef void *           HCERTSTORE;
        typedef void *           HCRYPTPROV_LEGACY;
        typedef struct _CERT_CONTEXT {
            unsigned long dwCertEncodingType;
            unsigned char *pbCertEncoded;
            unsigned long cbCertEncoded;
            void  *pCertInfo;
            HCERTSTORE hCertStore;
        } CERT_CONTEXT, *PCCERT_CONTEXT;

        typedef struct _CERT_ENHKEY_USAGE {
            unsigned long cUsageIdentifier;
            char        **rgpszUsageIdentifier;
        } CERT_ENHKEY_USAGE;

        typedef struct _CERT_USAGE_MATCH {
            unsigned long dwType;
            CERT_ENHKEY_USAGE Usage;
        } CERT_USAGE_MATCH;

        typedef struct _CERT_CHAIN_PARA {
            unsigned long cbSize;
            CERT_USAGE_MATCH RequestedUsage;
        } CERT_CHAIN_PARA;

        typedef struct _CERT_TRUST_STATUS {
            unsigned long dwErrorStatus;
            unsigned long dwInfoStatus;
        } CERT_TRUST_STATUS;

        typedef struct _CERT_CHAIN_CONTEXT {
            unsigned long cbSize;
            CERT_TRUST_STATUS TrustStatus;
            unsigned long cChain;
            void *rgpChain;
            unsigned long cLowerQualityChainContext;
            void *rgpLowerQualityChainContext;
            int   fHasRevocationFreshnessTime;
            unsigned long dwRevocationFreshnessTime;
        } CERT_CHAIN_CONTEXT, *PCCERT_CHAIN_CONTEXT;

        HCERTSTORE CertOpenSystemStoreA(HCRYPTPROV_LEGACY, const char *);
        BOOL       CertCloseStore(HCERTSTORE, unsigned long);
        const CERT_CONTEXT *CertEnumCertificatesInStore(HCERTSTORE, const CERT_CONTEXT *);
        const CERT_CONTEXT *CertCreateCertificateContext(unsigned long, const unsigned char *, unsigned long);
        BOOL       CertFreeCertificateContext(const CERT_CONTEXT *);
        BOOL       CertGetCertificateChain(HANDLE, const CERT_CONTEXT *, FILETIME *,
                                           HCERTSTORE, CERT_CHAIN_PARA *,
                                           unsigned long, void *, PCCERT_CHAIN_CONTEXT *);
        void       CertFreeCertificateChain(PCCERT_CHAIN_CONTEXT);
        HCERTSTORE CertOpenStore(LPCSTR, unsigned long, HCRYPTPROV_LEGACY,
                                  unsigned long, const void *);
        BOOL       CertAddEncodedCertificateToStore(HCERTSTORE, unsigned long,
                                                    const unsigned char *, unsigned long,
                                                    unsigned long, const CERT_CONTEXT **);
        ]]
        ffi.load("crypt32")
    end)
    _crypt32_loaded = ok
    return ok
end

local X509_ASN_ENCODING   = 0x00000001
local PKCS_7_ASN_ENCODING = 0x00010000
local CERT_ENC = X509_ASN_ENCODING + PKCS_7_ASN_ENCODING

local USAGE_MATCH_TYPE_AND = 0
local CERT_CHAIN_POLICY_BASE = 1
local CERT_STORE_ADD_ALWAYS  = 4

-- CertOpenStore provider id 2 (memory store); cast lazily because ffi/cdefs
-- aren't available until load_crypt32() runs.
local function MEMORY_PROVIDER() return ffi.cast("LPCSTR", 2) end

-- TrustStatus error bits we surface as human-readable reasons.
local TRUST_ERROR_BITS = {
    { 0x00000001, "not_signature_valid" },
    { 0x00000002, "not_time_valid" },
    { 0x00000004, "ctl_not_time_valid" },
    { 0x00000010, "is_revoked" },
    { 0x00000020, "invalid_extension" },
    { 0x00000040, "invalid_policy_constraints" },
    { 0x00000080, "invalid_basic_constraints" },
    { 0x00000100, "invalid_name_constraints" },
    { 0x00000200, "has_not_supported_name_constraint" },
    { 0x00000400, "has_not_defined_name_constraint" },
    { 0x00000800, "has_not_permitted_name_constraint" },
    { 0x00001000, "has_excluded_name_constraint" },
    { 0x01000000, "is_partial_chain" },
    { 0x02000000, "ctl_is_not_signature_valid" },
    { 0x04000000, "ctl_is_not_time_valid" },
    { 0x08000000, "ctl_is_not_valid_for_usage" },
    { 0x00010000, "is_untrusted_root" },
    { 0x00020000, "revocation_status_unknown" },
    { 0x00040000, "is_cyclic" },
    { 0x10000000, "has_weak_signature" },
}

local function explain_trust(dw)
    if dw == 0 then return "ok" end
    local reasons = {}
    for _, e in ipairs(TRUST_ERROR_BITS) do
        if (dw & e[1]) ~= 0 then reasons[#reasons + 1] = e[2] end
    end
    if #reasons == 0 then
        return string.format("unknown(0x%08X)", dw)
    end
    return table.concat(reasons, ",")
end

-- Validate a leaf cert (DER bytes) against the OS trust store. Optional
-- intermediates are spliced into a memory store so they're reachable during
-- chain construction.
local function verify_chain(leaf_der, intermediates)
    if not load_crypt32() then
        return nil, "crypt32 unavailable on this host"
    end
    intermediates = intermediates or {}
    local leaf_buf = ffi.new("unsigned char[?]", #leaf_der)
    ffi.copy(leaf_buf, leaf_der, #leaf_der)
    local leaf_ctx = ffi.C.CertCreateCertificateContext(CERT_ENC, leaf_buf, #leaf_der)
    if leaf_ctx == nil then return nil, "CertCreateCertificateContext (leaf) failed" end
    leaf_ctx = ffi.gc(leaf_ctx, ffi.C.CertFreeCertificateContext)

    -- Build an additional in-memory store carrying the intermediates so the
    -- chain engine can climb to a trusted root.
    local extra_store
    if #intermediates > 0 then
        extra_store = ffi.C.CertOpenStore(MEMORY_PROVIDER(), 0, nil, 0, nil)
        if extra_store ~= nil then
            extra_store = ffi.gc(extra_store, function(h) ffi.C.CertCloseStore(h, 0) end)
            for _, der in ipairs(intermediates) do
                local buf = ffi.new("unsigned char[?]", #der)
                ffi.copy(buf, der, #der)
                ffi.C.CertAddEncodedCertificateToStore(extra_store, CERT_ENC,
                                                      buf, #der, CERT_STORE_ADD_ALWAYS, nil)
            end
        end
    end

    local para = ffi.new("CERT_CHAIN_PARA")
    para.cbSize = ffi.sizeof("CERT_CHAIN_PARA")
    para.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND
    para.RequestedUsage.Usage.cUsageIdentifier = 0
    para.RequestedUsage.Usage.rgpszUsageIdentifier = nil

    local chain_ptr = ffi.new("PCCERT_CHAIN_CONTEXT[1]")
    local ok = ffi.C.CertGetCertificateChain(nil, leaf_ctx, nil,
        extra_store or leaf_ctx.hCertStore, para, 0, nil, chain_ptr)
    if ok == 0 or chain_ptr[0] == nil then
        return nil, "CertGetCertificateChain failed"
    end
    local chain = ffi.gc(chain_ptr[0], ffi.C.CertFreeCertificateChain)
    local err_status = chain.TrustStatus.dwErrorStatus
    if err_status == 0 then
        return true
    end
    return nil, explain_trust(err_status)
end

M.verify_chain = verify_chain

-- Enumerate every certificate in a named system store ("ROOT", "CA", "MY",
-- "TRUST", "DISALLOWED", ...). Returns a list of parsed cert tables.
function M.system_store(name)
    if not load_crypt32() then return nil, "crypt32 unavailable on this host" end
    local cname = ffi.new("char[?]", #name + 1)
    ffi.copy(cname, name)
    local store = ffi.C.CertOpenSystemStoreA(nil, cname)
    if store == nil then return nil, "CertOpenSystemStoreA failed" end
    store = ffi.gc(store, function(h) ffi.C.CertCloseStore(h, 0) end)
    local out = {}
    local ctx = nil
    while true do
        ctx = ffi.C.CertEnumCertificatesInStore(store, ctx)
        if ctx == nil then break end
        local der = ffi.string(ctx.pbCertEncoded, ctx.cbCertEncoded)
        local ok, parsed = pcall(M.parse_der, der)
        if ok then
            parsed.der = der
            out[#out + 1] = parsed
        end
    end
    return out
end

-- Wrap parse_der so each result carries its original DER and a :verify method.
local _parse_der_inner = M.parse_der
function M.parse_der(der)
    local cert = _parse_der_inner(der)
    cert.der = der
    cert.to_pem = cert_to_pem
    function cert:verify(intermediates) return verify_chain(self.der, intermediates) end
    return cert
end

return M
