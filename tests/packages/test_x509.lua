local x509 = require "x509"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_x509: " .. tostring(m)) end end

-- parse_time is a local function; it is exercised through the public
-- parse_der API, which surfaces the parsed validity as cert.not_before /
-- cert.not_after (epoch seconds). We hand-build minimal DER certificates whose
-- only meaningful content is a validity window with known 'Z' (UTC) timestamps,
-- then assert the decoded epoch equals the true UTC epoch -- independent of the
-- host timezone (the bug was that os.time treated the fields as LOCAL time).

local function tlv(tag, body)
    local len = #body
    local lenbytes
    if len < 0x80 then
        lenbytes = string.char(len)
    else
        local b = {}
        while len > 0 do table.insert(b, 1, string.char(len & 0xFF)); len = len >> 8 end
        lenbytes = string.char(0x80 | #b) .. table.concat(b)
    end
    return string.char(tag) .. lenbytes .. body
end

local function seq(body)       return tlv(0x30, body) end
local function setof(body)     return tlv(0x31, body) end
local function int(body)       return tlv(0x02, body) end
local function oid(body)       return tlv(0x06, body) end
local function bitstring(body) return tlv(0x03, "\0" .. body) end
local function utctime(s)      return tlv(0x17, s) end
local function gentime(s)      return tlv(0x18, s) end

-- Fixed scaffolding shared by every test cert.
local rsa_oid    = "\042\134\072\134\247\013\001\001\001" -- 1.2.840.113549.1.1.1
local sha256rsa  = "\042\134\072\134\247\013\001\001\011" -- 1.2.840.113549.1.1.11
local cn_oid     = "\085\004\003"                          -- 2.5.4.3 (CN)
local spki = seq(
    seq(oid(rsa_oid) .. tlv(0x05, "")) ..
    -- modulus kept >8 bytes so read_integer returns raw bytes (avoids overflow)
    bitstring(seq(int("\0\1\2\3\4\5\6\7\8\9") .. int("\3")))
)
local dn     = seq(setof(seq(oid(cn_oid) .. tlv(0x13, "x"))))
local sigalg = seq(oid(sha256rsa) .. tlv(0x05, ""))

local function build_cert(nb, na)
    local validity = seq(nb .. na)
    local tbs = seq(int("\1") .. sigalg .. dn .. validity .. dn .. spki)
    return seq(tbs .. sigalg .. bitstring("\0\0"))
end

-- KNOWN-CORRECT reference epochs (UTC), derived from the spec, not the code:
--   2024-01-01T00:00:00Z = 1704067200
--   1970-01-01T00:00:00Z = 0
--   2000-02-29T12:00:00Z = 951825600 (leap-day sanity check)

-- UTCTime stores 2-digit years: "240101000000Z" => 2024-01-01.
local c1 = x509.parse_der(build_cert(utctime("240101000000Z"), utctime("240101000000Z")))
ok(c1.not_before == 1704067200, "UTCTime 2024-01-01 not_before = " .. tostring(c1.not_before) .. " (want 1704067200)")
ok(c1.not_after  == 1704067200, "UTCTime 2024-01-01 not_after = "  .. tostring(c1.not_after)  .. " (want 1704067200)")

-- GeneralizedTime stores 4-digit years: "19700101000000Z" => epoch 0.
local c2 = x509.parse_der(build_cert(gentime("19700101000000Z"), gentime("19700101000000Z")))
ok(c2.not_before == 0, "GenTime 1970-01-01 not_before = " .. tostring(c2.not_before) .. " (want 0)")

-- UTCTime year < 50 => 20xx: "700101000000Z" => 1970-01-01 => epoch 0.
local c3 = x509.parse_der(build_cert(utctime("700101000000Z"), utctime("700101000000Z")))
ok(c3.not_before == 0, "UTCTime 1970-01-01 not_before = " .. tostring(c3.not_before) .. " (want 0)")

-- Leap-day at noon UTC.
local c4 = x509.parse_der(build_cert(gentime("20000229120000Z"), gentime("20000229120000Z")))
ok(c4.not_before == 951825600, "GenTime 2000-02-29T12:00:00Z = " .. tostring(c4.not_before) .. " (want 951825600)")

-- ===== Hostname matching (RFC 6125) =====================================
-- match_hostname() takes a PARSED cert table; build the relevant fields
-- directly (extensions.san + subject) to exercise the matcher without DER.
local function cert_with_san(sans, cn)
  return { extensions = { san = sans }, subject = cn and { { type = "CN", value = cn } } or {} }
end

-- Exact dNSName SAN.
do
  local c = cert_with_san({ "dns:example.com" })
  ok(x509.match_hostname(c, "example.com"),       "SAN exact match")
  ok(x509.match_hostname(c, "EXAMPLE.COM"),       "SAN match is case-insensitive")
  ok(not x509.match_hostname(c, "evil.com"),      "SAN rejects a different host")
  ok(not x509.match_hostname(c, "www.example.com"), "SAN exact does not match a subdomain")
end

-- Wildcard dNSName SAN: one leftmost label only.
do
  local c = cert_with_san({ "dns:*.example.com" })
  ok(x509.match_hostname(c, "www.example.com"),   "wildcard matches one label")
  ok(x509.match_hostname(c, "api.example.com"),   "wildcard matches another label")
  ok(not x509.match_hostname(c, "example.com"),   "wildcard does NOT match the bare domain")
  ok(not x509.match_hostname(c, "a.b.example.com"), "wildcard does NOT span two labels")
end

-- Unsafe wildcards rejected.
do
  ok(not x509.match_hostname(cert_with_san({ "dns:*.com" }), "evil.com"), "reject *.com (no embedded dot)")
  ok(not x509.match_hostname(cert_with_san({ "dns:*" }), "anything"),     "reject bare *")
end

-- Multiple SANs; one matches.
do
  local c = cert_with_san({ "dns:foo.com", "dns:bar.com", "dns:*.baz.com" })
  ok(x509.match_hostname(c, "bar.com"),           "matches the second SAN")
  ok(x509.match_hostname(c, "x.baz.com"),         "matches the wildcard SAN")
  ok(not x509.match_hostname(c, "qux.com"),       "no SAN matches qux.com")
end

-- IP-address SAN matched only for an IP literal host.
do
  local c = cert_with_san({ "ip:10.0.0.1", "dns:host.local" })
  ok(x509.match_hostname(c, "10.0.0.1"),          "IP SAN matches the IP literal")
  ok(not x509.match_hostname(c, "10.0.0.2"),      "IP SAN rejects a different IP")
  ok(x509.match_hostname(c, "host.local"),        "DNS SAN still matches its name")
end

-- CN fallback ONLY when there is no dNSName SAN.
do
  local cn_only = { extensions = { san = {} }, subject = { { type = "CN", value = "legacy.example" } } }
  ok(x509.match_hostname(cn_only, "legacy.example"), "CN fallback when no DNS SAN")
  -- With a DNS SAN present, the CN is ignored (cert is for other.com, CN says legacy).
  local san_present = { extensions = { san = { "dns:other.com" } },
                        subject    = { { type = "CN", value = "legacy.example" } } }
  ok(not x509.match_hostname(san_present, "legacy.example"), "CN ignored when a DNS SAN is present")
  ok(x509.match_hostname(san_present, "other.com"),          "DNS SAN used when present")
end

-- Defensive: bad inputs never throw, just return false.
ok(not x509.match_hostname(nil, "x"),  "nil cert -> false")
ok(not x509.match_hostname({}, ""),    "empty host -> false")

if fails == 0 then print("[+] PASS test_x509") os.exit(0) else os.exit(1) end
