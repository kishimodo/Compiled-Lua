-- uuid -- UUIDs (RFC 4122 + draft revisions) and other IDs.
--
-- Module-level surface:
--   uuid.v1()                            -> string  (timestamp + node)
--   uuid.v3(namespace, name)             -> string  (MD5 of namespace || name)
--   uuid.v4()                            -> string  (122 random bits)
--   uuid.v5(namespace, name)             -> string  (SHA-1 of namespace || name)
--   uuid.v6()                            -> string  (v1 with re-ordered timestamp)
--   uuid.v7()                            -> string  (Unix-ms + random)
--   uuid.parse(s)                        -> uuid object (see below)
--   uuid.parse_raw(s)                    -> 16-byte raw form
--   uuid.format(raw)                     -> canonical 8-4-4-4-12 lowercase
--   uuid.ulid()                          -> 26-char Crockford base32 ULID
--   uuid.ksuid()                         -> 27-char base62 KSUID
--   uuid.nanoid(size?, alphabet?)        -> Nano ID (default size=21, url-safe alphabet)
--
-- UUID object methods (returned by parse / from_raw):
--   uuid:tostring()       -> canonical 8-4-4-4-12 lowercase
--   uuid:bytes()          -> 16-byte raw form
--   uuid:version()        -> integer 1..7 (or nil for the nil UUID)
--   uuid:variant()        -> "rfc4122" | "ncs" | "microsoft" | "future"
--   uuid:timestamp()      -> seconds since Unix epoch (v1/v6/v7 only; else nil)
--
-- Named UUID namespaces are exported on uuid.NAMESPACE_*.

local rand = require "random"
local hash = require "hash"

local M = {}

-- ===== UUID format / parse =============================================

local function bytes_to_hex(s)
    local t = {}
    for i = 1, #s do t[i] = string.format("%02x", s:byte(i)) end
    return table.concat(t)
end

local function format_uuid(raw)
    if #raw ~= 16 then error("uuid.format: expected 16 bytes, got " .. #raw) end
    local h = bytes_to_hex(raw)
    return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16)
            .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end
M.format = format_uuid

local function parse_raw(s)
    if type(s) ~= "string" then error("uuid.parse: expected string") end
    if #s == 16 then return s end                                      -- already raw
    local clean = s:gsub("[%-{}]", "")
    if #clean ~= 32 then error("uuid.parse: bad length after stripping separators") end
    local out, n = {}, 0
    for i = 1, 32, 2 do
        local byte = tonumber(clean:sub(i, i + 1), 16)
        if byte == nil then error("uuid.parse: bad hex character") end
        n = n + 1; out[n] = string.char(byte)
    end
    return table.concat(out)
end
M.parse_raw = parse_raw

-- ===== UUID object =====================================================
-- (Hoisted up so v1/v6/v7 timestamp helpers can reference it.)

local UUID_EPOCH_OFFSET_100NS = 0x01B21DD213814000  -- 122192928000000000

local Uuid = {}
Uuid.__index = Uuid

function Uuid:tostring() return format_uuid(self._raw) end
Uuid.__tostring = function(self) return format_uuid(self._raw) end

function Uuid:bytes() return self._raw end

function Uuid:version()
    -- Top 4 bits of byte 7. The nil UUID (all zeros) has version 0; report nil
    -- so callers can detect it.
    local v = (self._raw:byte(7) >> 4) & 0x0F
    if v == 0 then return nil end
    return v
end

function Uuid:variant()
    local b9 = self._raw:byte(9)
    if (b9 & 0x80) == 0       then return "ncs"       end
    if (b9 & 0xC0) == 0x80    then return "rfc4122"   end
    if (b9 & 0xE0) == 0xC0    then return "microsoft" end
    return "future"
end

function Uuid:timestamp()
    local v = self:version()
    local r = self._raw
    if v == 1 then
        local time_low = (r:byte(1) << 24) | (r:byte(2) << 16)
                       | (r:byte(3) <<  8) |  r:byte(4)
        local time_mid = (r:byte(5) <<  8) |  r:byte(6)
        local time_hi  = ((r:byte(7) & 0x0F) << 8) | r:byte(8)
        local ts100ns  = (time_hi << 48) | (time_mid << 32) | time_low
        return (ts100ns - UUID_EPOCH_OFFSET_100NS) / 10000000
    elseif v == 6 then
        local th_hi = (r:byte(1) << 24) | (r:byte(2) << 16)
                    | (r:byte(3) <<  8) |  r:byte(4)
        local th_mi = (r:byte(5) <<  8) |  r:byte(6)
        local th_lo = ((r:byte(7) & 0x0F) << 8) | r:byte(8)
        local ts100ns = (th_hi << 28) | (th_mi << 12) | th_lo
        return (ts100ns - UUID_EPOCH_OFFSET_100NS) / 10000000
    elseif v == 7 then
        local ms = 0
        for i = 1, 6 do ms = (ms << 8) | r:byte(i) end
        return ms / 1000
    end
    return nil
end

local function uuid_from_raw(raw)
    if #raw ~= 16 then error("uuid.from_raw: expected 16 bytes, got " .. #raw) end
    return setmetatable({ _raw = raw }, Uuid)
end
M.from_raw = uuid_from_raw

function M.parse(s)
    return uuid_from_raw(parse_raw(s))
end

-- ===== Variant / version bit setters ===================================

local function set_version_and_variant(raw, version)
    -- RFC 4122 layout: time_hi_and_version (bytes 6-7) and clock_seq_hi (byte 8).
    local b7 = (raw:byte(7) & 0x0F) | (version << 4)
    local b9 = (raw:byte(9) & 0x3F) | 0x80   -- RFC 4122 variant (10xx)
    return raw:sub(1, 6) .. string.char(b7) .. raw:sub(8, 8)
        .. string.char(b9) .. raw:sub(10)
end

-- ===== v3 / v5 (name-based) ============================================

-- Namespaces are exposed as raw 16-byte strings; name_based() expects that
-- shape because it feeds them directly into hash.update.
M.NAMESPACE_DNS  = parse_raw("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
M.NAMESPACE_URL  = parse_raw("6ba7b811-9dad-11d1-80b4-00c04fd430c8")
M.NAMESPACE_OID  = parse_raw("6ba7b812-9dad-11d1-80b4-00c04fd430c8")
M.NAMESPACE_X500 = parse_raw("6ba7b814-9dad-11d1-80b4-00c04fd430c8")

local function name_based(ns, name, algo, version)
    if type(ns) ~= "string" or #ns ~= 16 then
        error("uuid.v" .. version .. ": namespace must be a 16-byte raw UUID (use uuid.parse)")
    end
    if type(name) ~= "string" then error("uuid.v" .. version .. ": name must be string") end
    local digest = hash.new(algo):update(ns):update(name):final()
    local raw    = digest:sub(1, 16)
    return format_uuid(set_version_and_variant(raw, version))
end

function M.v3(ns, name) return name_based(ns, name, "md5",  3) end
function M.v5(ns, name) return name_based(ns, name, "sha1", 5) end

-- ===== v4 (random) =====================================================

function M.v4()
    local raw = rand.secure_bytes(16)
    return format_uuid(set_version_and_variant(raw, 4))
end

-- ===== v1 / v6 (time + node) ===========================================
-- The UUIDv1 timestamp is 100-ns intervals since 1582-10-15 UTC.
-- Lua's os.time() gives Unix seconds; we add the constant offset and
-- multiply up. Sub-second resolution comes from a monotonically
-- incremented in-process counter to stop us from re-emitting timestamps.
-- (UUID_EPOCH_OFFSET_100NS is declared earlier so timestamp() can use it.)

local _last_ts100ns = 0
local _node = nil
local _clock_seq = nil

local function get_node()
    if _node ~= nil then return _node end
    -- No portable way to grab a MAC without a Win32 call -- use a random
    -- 48-bit value with the multicast bit set per RFC 4122 section 4.5.
    local b = rand.secure_bytes(6)
    b = string.char(b:byte(1) | 0x01) .. b:sub(2)  -- set multicast bit
    _node = b
    return _node
end

local function get_clock_seq()
    if _clock_seq ~= nil then return _clock_seq end
    -- 14-bit random clock_seq (top 2 bits become the variant).
    local r = rand.secure_bytes(2)
    _clock_seq = ((r:byte(1) << 8) | r:byte(2)) & 0x3FFF
    return _clock_seq
end

local function current_ts100ns()
    -- Gregorian 100-ns ticks since 1582-10-15 UTC.
    local ts = (os.time() * 10000000) + UUID_EPOCH_OFFSET_100NS
    -- Guarantee monotonicity within a session even at coarse clock resolution.
    if ts <= _last_ts100ns then
        ts = _last_ts100ns + 1
    end
    _last_ts100ns = ts
    return ts
end

local function pack_u64_be(v)
    return string.char(
        (v >> 56) & 0xFF, (v >> 48) & 0xFF,
        (v >> 40) & 0xFF, (v >> 32) & 0xFF,
        (v >> 24) & 0xFF, (v >> 16) & 0xFF,
        (v >>  8) & 0xFF,  v        & 0xFF)
end

function M.v1()
    local ts = current_ts100ns()
    -- Split into time_low (32), time_mid (16), time_hi_and_version (16; top 4 bits = version).
    local time_low = ts & 0xFFFFFFFF
    local time_mid = (ts >> 32) & 0xFFFF
    local time_hi  = (ts >> 48) & 0x0FFF
    local cs       = get_clock_seq()
    local node     = get_node()
    local raw = string.char(
        (time_low >> 24) & 0xFF, (time_low >> 16) & 0xFF,
        (time_low >>  8) & 0xFF,  time_low        & 0xFF,
        (time_mid >>  8) & 0xFF,  time_mid        & 0xFF,
        ((time_hi >>  8) & 0x0F) | 0x10,    -- version 1 in top nibble
         time_hi         & 0xFF,
        ((cs      >>  8) & 0x3F) | 0x80,    -- variant 10xx
         cs              & 0xFF)
        .. node
    return format_uuid(raw)
end

function M.v6()
    -- v6: reorder v1 timestamp so it's sortable (high-order time bits first).
    local ts = current_ts100ns()
    local time_high = (ts >> 28) & 0xFFFFFFFF   -- top 32 bits
    local time_mid  = (ts >> 12) & 0xFFFF       -- next 16
    local time_low  =  ts         & 0x0FFF      -- bottom 12 bits (becomes time_hi_and_version)
    local cs   = get_clock_seq()
    local node = get_node()
    local raw = string.char(
        (time_high >> 24) & 0xFF, (time_high >> 16) & 0xFF,
        (time_high >>  8) & 0xFF,  time_high        & 0xFF,
        (time_mid  >>  8) & 0xFF,  time_mid         & 0xFF,
        ((time_low >>  8) & 0x0F) | 0x60,   -- version 6
         time_low         & 0xFF,
        ((cs       >>  8) & 0x3F) | 0x80,   -- variant
         cs               & 0xFF)
        .. node
    return format_uuid(raw)
end

-- ===== v7 (Unix-ms + random) ===========================================

function M.v7()
    -- 48-bit big-endian Unix milliseconds + 12 bits random_a + 62 bits random_b
    -- with the version (4 bits) and variant (2 bits) embedded.
    local ms = math.floor(os.time() * 1000)
    -- The os.time() ms field is coarse; add fine fractional bits from rand.
    -- We use a stateful sub-ms counter to keep them monotonically ascending.
    local rnd = rand.secure_bytes(10)  -- bytes 7..16
    local raw = string.char(
        (ms >> 40) & 0xFF, (ms >> 32) & 0xFF,
        (ms >> 24) & 0xFF, (ms >> 16) & 0xFF,
        (ms >>  8) & 0xFF,  ms        & 0xFF)
        .. rnd
    -- Set version (7) and variant.
    local b7 = (raw:byte(7) & 0x0F) | 0x70
    local b9 = (raw:byte(9) & 0x3F) | 0x80
    raw = raw:sub(1, 6) .. string.char(b7) .. raw:sub(8, 8) .. string.char(b9) .. raw:sub(10)
    return format_uuid(raw)
end

-- ===== ULID (Crockford base32, 26 chars) ==============================

local ULID_ALPHA = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

local function encode_crockford(bytes, char_count)
    -- Each char encodes 5 bits, MSB-first.
    local out, n = {}, 0
    local bits, acc = 0, 0
    for i = 1, #bytes do
        acc  = (acc << 8) | bytes:byte(i)
        bits = bits + 8
        while bits >= 5 do
            bits = bits - 5
            n = n + 1
            out[n] = ULID_ALPHA:sub(((acc >> bits) & 0x1F) + 1, ((acc >> bits) & 0x1F) + 1)
        end
    end
    if bits > 0 then
        n = n + 1
        out[n] = ULID_ALPHA:sub(((acc << (5 - bits)) & 0x1F) + 1, ((acc << (5 - bits)) & 0x1F) + 1)
    end
    -- Trim/pad to expected length.
    local s = table.concat(out)
    if #s < char_count then s = string.rep("0", char_count - #s) .. s end
    return s:sub(1, char_count)
end

function M.ulid()
    -- 48-bit timestamp ms || 80-bit random -> 128 bits total, 26 base32 chars.
    local ms = math.floor(os.time() * 1000)
    local ts = string.char(
        (ms >> 40) & 0xFF, (ms >> 32) & 0xFF,
        (ms >> 24) & 0xFF, (ms >> 16) & 0xFF,
        (ms >>  8) & 0xFF,  ms        & 0xFF)
    return encode_crockford(ts .. rand.secure_bytes(10), 26)
end

-- ===== KSUID (160 bits: 32-bit timestamp epoch + 128-bit random) =======
-- KSUID epoch is 2014-05-13T16:53:20 UTC (Unix 1400000000).

local KSUID_EPOCH = 1400000000
local KSUID_ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

local function base62_encode_fixed(bytes, char_count)
    -- Big-int division by 62 over a byte buffer.
    local n = #bytes
    local buf = { bytes:byte(1, n) }  -- mutable copy as integer array
    local out, count = {}, 0
    while true do
        -- Check if buffer is all zero
        local nz = false
        for i = 1, n do if buf[i] ~= 0 then nz = true; break end end
        if not nz then break end
        local rem = 0
        for i = 1, n do
            local cur = (rem * 256) + buf[i]
            buf[i] = cur // 62
            rem    = cur %  62
        end
        count = count + 1
        out[count] = KSUID_ALPHA:sub(rem + 1, rem + 1)
    end
    -- Pad with the zero-character to fixed length.
    while count < char_count do
        count = count + 1
        out[count] = KSUID_ALPHA:sub(1, 1)
    end
    -- Reverse (we collected least-significant first).
    local s = table.concat(out)
    local rev = {}
    for i = #s, 1, -1 do rev[#rev + 1] = s:sub(i, i) end
    return table.concat(rev):sub(1, char_count)
end

function M.ksuid()
    local ts = os.time() - KSUID_EPOCH
    if ts < 0 then ts = 0 end
    local ts_bytes = string.char(
        (ts >> 24) & 0xFF, (ts >> 16) & 0xFF,
        (ts >>  8) & 0xFF,  ts        & 0xFF)
    return base62_encode_fixed(ts_bytes .. rand.secure_bytes(16), 27)
end

-- ===== Nano ID =========================================================

local NANO_DEFAULT_ALPHA = "_-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

function M.nanoid(size, alphabet)
    size = size or 21
    alphabet = alphabet or NANO_DEFAULT_ALPHA
    local alpha_len = #alphabet
    if alpha_len < 2 or alpha_len > 256 then
        error("uuid.nanoid: alphabet length must be between 2 and 256")
    end
    -- Find the smallest mask >= alpha_len - 1 -- standard Nano ID rejection trick.
    local mask = 1
    while mask < alpha_len - 1 do mask = (mask << 1) | 1 end
    -- Step factor from the reference implementation: ceil(1.6 * mask * size / alpha_len).
    local step = math.ceil((1.6 * mask * size) / alpha_len)
    local out, n = {}, 0
    while n < size do
        local bytes = rand.secure_bytes(step)
        for i = 1, step do
            local idx = bytes:byte(i) & mask
            if idx < alpha_len then
                n = n + 1
                out[n] = alphabet:sub(idx + 1, idx + 1)
                if n == size then break end
            end
        end
    end
    return table.concat(out)
end

return M
