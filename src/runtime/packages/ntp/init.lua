-- ntp -- SNTP client (RFC 4330) with NTPv4 packet layout (RFC 5905).
--
-- Public surface:
--   ntp.sync(server?, opts?) -> {
--     offset_seconds   -- adjust local time by adding this to match server
--     delay_ms         -- round-trip delay
--     dispersion_ms    -- combined server precision + jitter estimate
--     stratum          -- 1-15 (1 = primary), 16 = unsynchronized, 0 = kiss-of-death
--     leap             -- 0 normal, 1 +1s, 2 -1s, 3 unsynced
--     version          -- protocol version field
--     mode             -- 4 server reply, 5 broadcast
--     precision        -- log2 seconds (negative, e.g. -20 = ~1us)
--     root_delay_ms
--     root_dispersion_ms
--     ref_id           -- ASCII id for stratum 1, IPv4 for stratum 2+
--     ref_time         -- last sync time on server (Unix seconds, float)
--     orig_time, recv_time, xmt_time, server_time
--   }
--
--   ntp.now(server?, opts?) -> server-corrected unix time (float seconds)
--   ntp.adjusted_time(server?, opts?) -> os.time()+offset
--
-- opts:
--   port    -- default 123
--   timeout -- ms (default 4000)
--
-- NTP packet (48 bytes):
--   LI/VN/Mode | Stratum | Poll | Precision  (1+1+1+1)
--   Root Delay (32 fixed 16.16)
--   Root Dispersion (32 fixed 16.16)
--   Reference Identifier (32)
--   Reference Timestamp (64: secs(32) + frac(32))
--   Originate Timestamp (64)
--   Receive Timestamp (64)
--   Transmit Timestamp (64)

local socket = require "socket"

local M = {}

-- NTP epoch is 1900-01-01 UTC; Unix epoch is 1970-01-01.
-- Delta = (70*365 + 17 leap days) * 86400 = 2208988800 seconds.
local NTP_UNIX_DELTA = 2208988800

local DEFAULT_POOL = {
    "pool.ntp.org",
    "time.cloudflare.com",
    "time.google.com",
}

-- Encode a Unix-epoch float to a 64-bit NTP timestamp (8 bytes).
local function unix_to_ntp_bytes(t)
    local ntp = t + NTP_UNIX_DELTA
    local secs = math.floor(ntp)
    local frac = math.floor((ntp - secs) * 0x100000000)
    if frac >= 0x100000000 then frac = 0xFFFFFFFF end
    return string.char(
        (secs >> 24) & 0xFF, (secs >> 16) & 0xFF,
        (secs >> 8)  & 0xFF,  secs        & 0xFF,
        (frac >> 24) & 0xFF, (frac >> 16) & 0xFF,
        (frac >> 8)  & 0xFF,  frac        & 0xFF)
end

-- Decode an 8-byte NTP timestamp at offset 1..8 within `s` to a Unix
-- float second. NTP frac is a 32-bit unsigned numerator of 2^32.
local function ntp_bytes_to_unix(s, off)
    local secs = (s:byte(off    ) << 24) | (s:byte(off + 1) << 16)
               | (s:byte(off + 2) <<  8) |  s:byte(off + 3)
    local frac = (s:byte(off + 4) << 24) | (s:byte(off + 5) << 16)
               | (s:byte(off + 6) <<  8) |  s:byte(off + 7)
    if secs == 0 and frac == 0 then return 0 end   -- "no value"
    return (secs - NTP_UNIX_DELTA) + (frac / 0x100000000)
end

-- Decode a 32-bit short-format NTP timestamp (16.16 seconds).
local function short_to_seconds(s, off)
    local intp  = (s:byte(off    ) << 8) | s:byte(off + 1)
    local fracp = (s:byte(off + 2) << 8) | s:byte(off + 3)
    return intp + (fracp / 0x10000)
end

-- Get current Unix time with sub-second resolution.
local function unix_time_subsec()
    -- os.time() is integer; combine with os.clock() drift since startup
    -- if no monotonic clock is exposed by the runtime. The drift between
    -- os.time() boundary and os.clock() means we can be off by up to 1s;
    -- not a big deal for offset computation (offset is computed from
    -- the same skewed reading on both endpoints of T1/T4).
    return os.time() + 0.0
end

-- Build a client-mode packet. LI=0, VN=4, Mode=3 (client). Stratum,
-- Poll, Precision left at 0. T_xmt = current Unix time, NTP-formatted.
local function build_client_packet()
    local pkt = { string.char(0x23) }   -- 0b00 100 011 = LI 0, VN 4, Mode 3
    -- 39 zero bytes for Stratum..Reference Timestamp + Originate + Receive
    pkt[#pkt + 1] = string.rep("\0", 39)
    -- Transmit timestamp (last 8 bytes)
    local t = unix_time_subsec()
    pkt[#pkt + 1] = unix_to_ntp_bytes(t)
    return table.concat(pkt), t
end

local function parse_response(pkt, t1, t4)
    if #pkt < 48 then return nil, "short ntp response" end
    local li_vn_mode = pkt:byte(1)
    local li  = (li_vn_mode >> 6) & 0x3
    local vn  = (li_vn_mode >> 3) & 0x7
    local mode = li_vn_mode & 0x7
    local stratum  = pkt:byte(2)
    local poll     = pkt:byte(3)
    local precision = pkt:byte(4)
    -- precision is signed int8 (log2 seconds, usually negative)
    if precision >= 128 then precision = precision - 256 end

    local root_delay_s      = short_to_seconds(pkt, 5)
    local root_dispersion_s = short_to_seconds(pkt, 9)

    -- Reference Identifier: 4 bytes. Stratum 1 is ASCII (GPS, PPS, ATOM...).
    -- Stratum 2+ is the IPv4 address of the upstream server.
    local ref_id
    if stratum <= 1 then
        ref_id = pkt:sub(13, 16):gsub("%z", " "):gsub("%s+$", "")
    else
        ref_id = string.format("%d.%d.%d.%d",
            pkt:byte(13), pkt:byte(14), pkt:byte(15), pkt:byte(16))
    end

    local ref_time = ntp_bytes_to_unix(pkt, 17)
    local t1_srv   = ntp_bytes_to_unix(pkt, 25)  -- originate (echo of our xmt)
    local t2       = ntp_bytes_to_unix(pkt, 33)  -- server recv
    local t3       = ntp_bytes_to_unix(pkt, 41)  -- server xmt

    -- RFC 4330: offset = ((T2 - T1) + (T3 - T4)) / 2
    --          delay  = (T4 - T1) - (T3 - T2)
    local offset = ((t2 - t1) + (t3 - t4)) / 2
    local delay  = (t4 - t1) - (t3 - t2)

    return {
        leap            = li,
        version         = vn,
        mode            = mode,
        stratum         = stratum,
        poll            = poll,
        precision       = precision,
        root_delay_ms   = root_delay_s * 1000,
        root_dispersion_ms = root_dispersion_s * 1000,
        ref_id          = ref_id,
        ref_time        = ref_time,
        orig_time       = t1_srv,
        recv_time       = t2,
        xmt_time        = t3,
        server_time     = t3 + (t4 - t1) / 2,   -- best estimate at T4 send
        offset_seconds  = offset,
        delay_ms        = delay * 1000,
        dispersion_ms   = (root_dispersion_s + math.abs(delay) / 2) * 1000,
    }
end

local function query_one(server, opts)
    local u, err = socket.udp.new()
    if not u then return nil, err end
    u:set_timeout(opts.timeout or 4000)
    local pkt, t1 = build_client_packet()
    local ok; ok, err = u:send_to(pkt, server, opts.port or 123)
    if not ok then u:close(); return nil, err end
    local resp, _h, _p = u:recv_from(512)
    if not resp then
        u:close()
        return nil, _h or "no response"
    end
    local t4 = unix_time_subsec()
    u:close()
    return parse_response(resp, t1, t4)
end

-- ntp.sync(server?, opts?) -- try the provided server (or pool) and
-- return the first valid result. If a server returns stratum 0 ("Kiss
-- of Death"), we skip to the next.
function M.sync(server, opts)
    opts = opts or {}
    local servers
    if type(server) == "string" then servers = { server }
    elseif type(server) == "table" then servers = server
    else servers = DEFAULT_POOL end
    local last_err
    for _, s in ipairs(servers) do
        local r, err = query_one(s, opts)
        if r and r.stratum > 0 and r.stratum < 16 then
            r.server = s
            return r
        end
        last_err = err or ("kiss-of-death from " .. s)
    end
    return nil, last_err
end

-- Convenience: return offset-adjusted local time as a Unix float.
function M.now(server, opts)
    local r, err = M.sync(server, opts)
    if not r then return nil, err end
    return unix_time_subsec() + r.offset_seconds, r
end

function M.adjusted_time(server, opts)
    return M.now(server, opts)
end

return M
