-- dns -- DNS resolver: system path (DnsQuery_W) + pure-Lua implementation.
--
-- Public surface:
--   dns.resolve(name, type?, opts?)
--     name : "example.com"
--     type : "A" (default) | "AAAA" | "MX" | "TXT" | "CNAME" | "SRV"
--          | "PTR" | "NS" | "SOA" | "CAA" | "ANY"
--     opts:
--       server     -- "8.8.8.8" or { "1.1.1.1", "8.8.8.8" }; default system
--       method     -- "system" | "udp" | "tcp" | "doh" | "dot"; default udp
--                     "system" routes to DnsQuery_W; everything else is the
--                     pure-Lua implementation
--       doh_url    -- DoH endpoint, default "https://cloudflare-dns.com/dns-query"
--       dot_host   -- DoT hostname, default "1.1.1.1"
--       dot_port   -- DoT port, default 853
--       timeout    -- ms, default 5000
--       recursion  -- default true (RD flag)
--   Returns: { records } where each record = { type=..., name=..., ttl=..., ... }
--     A:     { ip = "1.2.3.4" }
--     AAAA:  { ip = "::1" }
--     CNAME: { target = "x.example.com" }
--     NS:    { ns = "ns1.example.com" }
--     PTR:   { target = "host.example.com" }
--     MX:    { preference = 10, exchange = "mx.example.com" }
--     TXT:   { strings = { "v=spf1 ..." } }    -- one entry per <character-string>
--     SRV:   { priority = ..., weight = ..., port = ..., target = ... }
--     SOA:   { mname=, rname=, serial=, refresh=, retry=, expire=, minimum= }
--     CAA:   { flags = ..., tag = "issue", value = "letsencrypt.org" }
--
--   Convenience: dns.a(name) / dns.aaaa(name) / dns.mx(name) / dns.txt(name)
--                dns.srv(name) / dns.ptr(name)
--   PTR convenience: dns.reverse("1.2.3.4") -- builds in-addr.arpa, queries PTR

local ffi    = ffi
require "windows"
local socket = require "socket"
local tls    = require "tls_client"
local http   = require "http"

local M = {}

-- ============================================================
-- DNS message format helpers
-- ============================================================
--
-- Header (12 bytes):
--   ID(16) | QR/Opcode/AA/TC/RD(8) RA/Z/RCODE(8) | QDCOUNT(16) ANCOUNT(16) NSCOUNT(16) ARCOUNT(16)
--
-- Question:
--   QNAME (length-prefixed labels, 0 terminator) | QTYPE(16) | QCLASS(16)
--
-- Answer RR:
--   NAME | TYPE | CLASS | TTL(32) | RDLENGTH(16) | RDATA

local TYPE_A     = 1
local TYPE_NS    = 2
local TYPE_CNAME = 5
local TYPE_SOA   = 6
local TYPE_PTR   = 12
local TYPE_MX    = 15
local TYPE_TXT   = 16
local TYPE_AAAA  = 28
local TYPE_SRV   = 33
local TYPE_CAA   = 257
local TYPE_ANY   = 255
local CLASS_IN   = 1

local _name_to_type = {
    A = TYPE_A,  NS = TYPE_NS,  CNAME = TYPE_CNAME, SOA = TYPE_SOA,
    PTR = TYPE_PTR, MX = TYPE_MX, TXT = TYPE_TXT, AAAA = TYPE_AAAA,
    SRV = TYPE_SRV, CAA = TYPE_CAA, ANY = TYPE_ANY,
}
local _type_to_name = {}
for k, v in pairs(_name_to_type) do _type_to_name[v] = k end

local function encode_name(name)
    -- "example.com." -> "\7example\3com\0"
    if name:sub(-1) == "." then name = name:sub(1, -2) end
    local parts = {}
    for label in name:gmatch("[^.]+") do
        if #label > 63 then error("dns: label too long") end
        parts[#parts + 1] = string.char(#label) .. label
    end
    return table.concat(parts) .. "\0"
end

-- Decode a name beginning at offset i. Supports RFC 1035 compression
-- (top two bits 11 -> 14-bit pointer back into the message).
local function decode_name(msg, i)
    local labels, jumped, orig_i = {}, false, i
    local steps = 0
    while true do
        steps = steps + 1
        if steps > 256 then return nil, nil, "compression loop" end
        local b = msg:byte(i)
        if not b then return nil, nil, "name overruns message" end
        if b == 0 then
            i = i + 1
            if not jumped then orig_i = i end
            return table.concat(labels, "."), orig_i
        elseif (b & 0xC0) == 0xC0 then
            local b2 = msg:byte(i + 1)
            local ptr = ((b & 0x3F) << 8) | b2
            if not jumped then orig_i = i + 2 end
            i = ptr + 1   -- 1-based offset to byte at ptr
            jumped = true
        else
            i = i + 1
            labels[#labels + 1] = msg:sub(i, i + b - 1)
            i = i + b
        end
    end
end

local function read_u16(msg, i) return (msg:byte(i) << 8) | msg:byte(i + 1), i + 2 end
local function read_u32(msg, i)
    return (msg:byte(i) << 24) | (msg:byte(i + 1) << 16)
         | (msg:byte(i + 2) << 8) | msg:byte(i + 3), i + 4
end
local function pack_u16(n) return string.char((n >> 8) & 0xFF, n & 0xFF) end

-- ============================================================
-- Query building
-- ============================================================

local function build_query(name, qtype, opts)
    local id = math.random(1, 0xFFFF)
    local flags = 0
    if opts.recursion ~= false then flags = flags | 0x0100 end -- RD
    local hdr = pack_u16(id) .. pack_u16(flags)
              .. pack_u16(1) .. pack_u16(0) .. pack_u16(0) .. pack_u16(0)
    local q = encode_name(name) .. pack_u16(qtype) .. pack_u16(CLASS_IN)
    return hdr .. q, id
end

-- ============================================================
-- Response parsing
-- ============================================================

local function parse_rdata(qtype, msg, off, rdlen)
    local r = {}
    if qtype == TYPE_A and rdlen == 4 then
        r.ip = string.format("%d.%d.%d.%d",
            msg:byte(off), msg:byte(off + 1), msg:byte(off + 2), msg:byte(off + 3))
    elseif qtype == TYPE_AAAA and rdlen == 16 then
        local parts = {}
        for i = 0, 7 do
            parts[i + 1] = string.format("%x",
                (msg:byte(off + i * 2) << 8) | msg:byte(off + i * 2 + 1))
        end
        r.ip = table.concat(parts, ":")
        -- Collapse longest run of "0" groups into "::" (canonical form).
        -- Cheap canonicalization: replace first sequence of 2+ ":0" patterns.
        r.ip = r.ip:gsub(":0:0:0:0:0:0:0", ":")
                  :gsub(":0:0:0:0:0:0", ":")
                  :gsub(":0:0:0:0:0", ":")
                  :gsub(":0:0:0:0", ":")
                  :gsub(":0:0:0", ":")
                  :gsub(":0:0", ":")
        if r.ip:sub(1, 1) == ":" and r.ip:sub(2, 2) ~= ":" then r.ip = ":" .. r.ip end
    elseif qtype == TYPE_CNAME then
        r.target = (decode_name(msg, off))
    elseif qtype == TYPE_NS then
        r.ns = (decode_name(msg, off))
    elseif qtype == TYPE_PTR then
        r.target = (decode_name(msg, off))
    elseif qtype == TYPE_MX then
        r.preference = (msg:byte(off) << 8) | msg:byte(off + 1)
        r.exchange   = (decode_name(msg, off + 2))
    elseif qtype == TYPE_TXT then
        -- Series of length-prefixed character-strings.
        local strs, i = {}, off
        local stop = off + rdlen
        while i < stop do
            local L = msg:byte(i)
            strs[#strs + 1] = msg:sub(i + 1, i + L)
            i = i + 1 + L
        end
        r.strings = strs
        r.text    = table.concat(strs)
    elseif qtype == TYPE_SRV then
        r.priority = (msg:byte(off) << 8) | msg:byte(off + 1)
        r.weight   = (msg:byte(off + 2) << 8) | msg:byte(off + 3)
        r.port     = (msg:byte(off + 4) << 8) | msg:byte(off + 5)
        r.target   = (decode_name(msg, off + 6))
    elseif qtype == TYPE_SOA then
        local mname, p = decode_name(msg, off)
        local rname; rname, p = decode_name(msg, p)
        r.mname   = mname
        r.rname   = rname
        r.serial,  p = read_u32(msg, p)
        r.refresh, p = read_u32(msg, p)
        r.retry,   p = read_u32(msg, p)
        r.expire,  p = read_u32(msg, p)
        r.minimum    = read_u32(msg, p)
    elseif qtype == TYPE_CAA then
        r.flags = msg:byte(off)
        local taglen = msg:byte(off + 1)
        r.tag   = msg:sub(off + 2, off + 1 + taglen)
        r.value = msg:sub(off + 2 + taglen, off + rdlen - 1)
    else
        r.raw = msg:sub(off, off + rdlen - 1)
    end
    return r
end

local function parse_response(msg)
    if #msg < 12 then return nil, "truncated response" end
    local id      = (msg:byte(1) << 8) | msg:byte(2)
    local flags   = (msg:byte(3) << 8) | msg:byte(4)
    local qcount  = (msg:byte(5) << 8) | msg:byte(6)
    local ancount = (msg:byte(7) << 8) | msg:byte(8)
    local rcode   = flags & 0x0F
    if rcode ~= 0 then
        local names = { [0]="NOERROR", [1]="FORMERR", [2]="SERVFAIL",
            [3]="NXDOMAIN", [4]="NOTIMP", [5]="REFUSED" }
        return nil, "dns rcode " .. (names[rcode] or rcode)
    end
    -- Skip the question section
    local i = 13
    for _ = 1, qcount do
        local _; _, i = decode_name(msg, i)
        i = i + 4   -- QTYPE + QCLASS
    end
    local records = {}
    for _ = 1, ancount do
        local name, p = decode_name(msg, i); i = p
        local rtype;   rtype, i = read_u16(msg, i)
        local _rclass; _rclass, i = read_u16(msg, i)
        local ttl;     ttl, i  = read_u32(msg, i)
        local rdlen;   rdlen, i = read_u16(msg, i)
        local rdata = parse_rdata(rtype, msg, i, rdlen)
        rdata.name = name
        rdata.ttl  = ttl
        rdata.type = _type_to_name[rtype] or rtype
        records[#records + 1] = rdata
        i = i + rdlen
    end
    return records, id
end

-- ============================================================
-- Transport: UDP / TCP / DoT / DoH
-- ============================================================

local function query_udp(server, query, timeout)
    local u, err = socket.udp.new()
    if not u then return nil, err end
    if timeout then u:set_timeout(timeout) end
    local ok; ok, err = u:send_to(query, server, 53)
    if not ok then u:close(); return nil, err end
    local data, _h, _p = u:recv_from(65535)
    u:close()
    if not data then return nil, _h end
    -- If TC bit set in flags, fall back to TCP.
    if #data >= 4 and (data:byte(3) & 0x02) ~= 0 then
        return nil, "tc-set"   -- caller retries via TCP
    end
    return data
end

local function query_tcp(server, query, timeout)
    local s, err = socket.tcp.connect(server, 53,
        { timeout = timeout, nodelay = true })
    if not s then return nil, err end
    -- RFC 7766: 2-byte big-endian length prefix.
    s:write(pack_u16(#query) .. query)
    local hdr; hdr, err = s:read_exact(2)
    if not hdr then s:close(); return nil, err end
    local L = (hdr:byte(1) << 8) | hdr:byte(2)
    local data, derr = s:read_exact(L)
    s:close()
    if not data then return nil, derr end
    return data
end

local function query_dot(host, port, query, opts)
    local c, err = tls.connect(host, port, {
        timeout = opts.timeout, verify = opts.verify,
        server_name = opts.server_name or host,
    })
    if not c then return nil, err end
    c:write(pack_u16(#query) .. query)
    local hdr; hdr, err = c:read_exact(2)
    if not hdr then c:close(); return nil, err end
    local L = (hdr:byte(1) << 8) | hdr:byte(2)
    local data, derr = c:read_exact(L)
    c:close()
    if not data then return nil, derr end
    return data
end

local function query_doh(url, query, opts)
    -- RFC 8484: POST application/dns-message with raw DNS wire format.
    local resp, err = http.request("POST", url, {
        headers = {
            ["Content-Type"] = "application/dns-message",
            ["Accept"]       = "application/dns-message",
        },
        body    = query,
        timeout = opts.timeout,
        decompress = false,
    })
    if not resp then return nil, err end
    if resp.status ~= 200 then return nil, "DoH HTTP " .. resp.status end
    return resp.body
end

-- ============================================================
-- System path (DnsQuery_W via dnsapi.dll)
-- ============================================================
--
-- Used only for type="system", or when method="system" is passed
-- explicitly. The pure-Lua path is the default because it lets callers
-- swap resolvers, hit DoH/DoT, etc.

ffi.cdef[[
typedef struct dns_IP4_ARRAY {
    unsigned long AddrCount;
    unsigned long AddrArray[1];
} dns_IP4_ARRAY;

typedef struct dns_RECORD {
    void *         pNext;
    unsigned short *pName;
    unsigned short wType;
    unsigned short wDataLength;
    unsigned long  Flags;
    unsigned long  dwTtl;
    unsigned long  dwReserved;
    unsigned char  Data[1024];
} dns_RECORD;

long DnsQuery_W(const unsigned short *, unsigned short, unsigned long,
                void *, dns_RECORD **, void *);
void DnsRecordListFree(dns_RECORD *, int);
]]
pcall(ffi.load, "dnsapi")

local function query_system(name, qtype)
    -- Encode hostname as UTF-16 BE (Windows uses LE so just byte-by-byte).
    local n = #name
    local wide = ffi.new("unsigned short[?]", n + 1)
    for i = 1, n do wide[i - 1] = name:byte(i) end
    wide[n] = 0
    local results = ffi.new("dns_RECORD *[1]")
    local rc = ffi.C.DnsQuery_W(wide, qtype, 0, nil, results, nil)
    if rc ~= 0 then
        return nil, "DnsQuery_W failed: " .. rc
    end
    local out = {}
    local rec = results[0]
    while rec ~= nil do
        local t = rec.wType
        if t == qtype or qtype == TYPE_ANY then
            local r = { type = _type_to_name[t] or t, ttl = rec.dwTtl }
            if t == TYPE_A then
                local v = ffi.cast("unsigned long *", rec.Data)[0]
                r.ip = string.format("%d.%d.%d.%d",
                    v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF)
            elseif t == TYPE_AAAA then
                local parts = {}
                for i = 0, 7 do
                    parts[i + 1] = string.format("%x",
                        (rec.Data[i * 2] << 8) | rec.Data[i * 2 + 1])
                end
                r.ip = table.concat(parts, ":"):gsub("(:0)+:", "::", 1)
            end
            -- System path mostly handles A/AAAA; for the rest use pure
            -- Lua. Callers passing method="system" with MX/TXT/SRV will
            -- get raw records here, but it's a minor surface.
            out[#out + 1] = r
        end
        rec = ffi.cast("dns_RECORD *", rec.pNext)
    end
    ffi.C.DnsRecordListFree(results[0], 1)
    return out
end

-- ============================================================
-- Public entry: resolve()
-- ============================================================

local DEFAULT_DOH = "https://cloudflare-dns.com/dns-query"
local DEFAULT_DOT_HOST = "1.1.1.1"
local DEFAULT_SERVERS  = { "1.1.1.1", "8.8.8.8" }

function M.resolve(name, qtype_str, opts)
    opts = opts or {}
    qtype_str = qtype_str or "A"
    local qtype = _name_to_type[qtype_str:upper()]
        or error("dns: unknown type " .. tostring(qtype_str))

    local method = opts.method or "udp"
    if method == "system" then
        return query_system(name, qtype)
    end

    local query, qid = build_query(name, qtype, opts)
    local timeout = opts.timeout or 5000

    if method == "doh" then
        local data, err = query_doh(opts.doh_url or DEFAULT_DOH, query,
            { timeout = timeout })
        if not data then return nil, err end
        return parse_response(data)
    end

    if method == "dot" then
        local host = opts.dot_host or DEFAULT_DOT_HOST
        local port = opts.dot_port or 853
        local data, err = query_dot(host, port, query,
            { timeout = timeout, verify = opts.verify,
              server_name = opts.server_name or host })
        if not data then return nil, err end
        return parse_response(data)
    end

    if method == "tcp" then
        local servers = opts.server
        if type(servers) ~= "table" then servers = { servers or DEFAULT_SERVERS[1] } end
        local last_err
        for _, srv in ipairs(servers) do
            local data, err = query_tcp(srv, query, timeout)
            if data then return parse_response(data) end
            last_err = err
        end
        return nil, last_err
    end

    -- udp (default): try each server, retry first one over tcp on TC.
    local servers = opts.server
    if type(servers) ~= "table" then
        if servers then servers = { servers } else servers = DEFAULT_SERVERS end
    end
    local last_err = "no servers"
    for _, srv in ipairs(servers) do
        local data, err = query_udp(srv, query, timeout)
        if data then return parse_response(data) end
        if err == "tc-set" then
            data, err = query_tcp(srv, query, timeout)
            if data then return parse_response(data) end
        end
        last_err = err
    end
    return nil, last_err
end

-- ============================================================
-- Convenience wrappers
-- ============================================================

local function pick_field(records, field)
    if not records then return nil end
    local out = {}
    for _, r in ipairs(records) do
        if r[field] then out[#out + 1] = r[field] end
    end
    return out
end

function M.a(name, opts)
    local r, e = M.resolve(name, "A", opts)
    return pick_field(r, "ip"), e
end
function M.aaaa(name, opts)
    local r, e = M.resolve(name, "AAAA", opts)
    return pick_field(r, "ip"), e
end
function M.mx(name, opts) return M.resolve(name, "MX", opts) end
function M.txt(name, opts) return M.resolve(name, "TXT", opts) end
function M.srv(name, opts) return M.resolve(name, "SRV", opts) end
function M.cname(name, opts) return M.resolve(name, "CNAME", opts) end
function M.ns(name, opts) return M.resolve(name, "NS", opts) end
function M.soa(name, opts) return M.resolve(name, "SOA", opts) end
function M.caa(name, opts) return M.resolve(name, "CAA", opts) end

-- dns.reverse("1.2.3.4") -> reverse PTR records
function M.reverse(ip, opts)
    local arpa
    if ip:find(":", 1, true) then
        -- IPv6: reverse nibbles of expanded address into ip6.arpa.
        -- Expand "::" stub: count colons, fill gap with zero groups.
        local groups = {}
        for g in ip:gmatch("([^:]+)") do groups[#groups + 1] = g end
        if ip:find("::", 1, true) and #groups < 8 then
            local fill = {}
            for _ = 1, 8 - #groups do fill[#fill + 1] = "0" end
            local idx = 1
            local newg = {}
            for g in ip:gmatch("(:?[^:]*)") do
                if g == ":" then
                    for _, f in ipairs(fill) do newg[#newg + 1] = f end
                elseif g ~= "" then
                    newg[#newg + 1] = g
                end
            end
            groups = newg
        end
        local nibbles = {}
        for _, g in ipairs(groups) do
            local padded = string.format("%04x", tonumber(g, 16) or 0)
            nibbles[#nibbles + 1] = padded
        end
        local full = table.concat(nibbles)
        local rev = {}
        for i = #full, 1, -1 do rev[#rev + 1] = full:sub(i, i) end
        arpa = table.concat(rev, ".") .. ".ip6.arpa"
    else
        local parts = {}
        for p in ip:gmatch("(%d+)") do parts[#parts + 1] = p end
        arpa = parts[4] .. "." .. parts[3] .. "." .. parts[2] .. "." .. parts[1] .. ".in-addr.arpa"
    end
    return M.resolve(arpa, "PTR", opts)
end

return M
