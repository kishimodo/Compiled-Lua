-- geoip -- MaxMind .mmdb binary-format reader (pure Lua, no DLL).
--
-- Public surface:
--   geoip.open(path)              -> reader
--   reader:lookup(ip)             -> data table | nil
--   reader:metadata()             -> { build_epoch, database_type, languages,
--                                       node_count, record_size, ip_version,
--                                       binary_format_major_version, ... }
--   reader:close()                -> ()
--
-- Format reference: https://maxmind.github.io/MaxMind-DB/
--   File layout:
--     [ binary tree ] [ data section ] [ metadata-marker || metadata-map ]
--   The metadata marker is the 14-byte sequence:
--     \xAB\xCD\xEFMaxMind.com
--   It appears once near the end of the file. The map that follows is a
--   data-section value whose first byte uses the standard control-byte
--   encoding.

local M = {}

local METADATA_MARKER = "\xAB\xCD\xEFMaxMind.com"

-- ===== bit / int helpers ===============================================

local function u8(s, i) return s:byte(i) end

local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    return a * 0x100 + b
end

local function u24(s, i)
    local a, b, c = s:byte(i, i + 2)
    return a * 0x10000 + b * 0x100 + c
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

local function uN(s, i, n)
    if n == 0 then return 0 end
    local v = 0
    for k = 0, n - 1 do
        v = v * 256 + s:byte(i + k)
    end
    return v
end

-- IEEE 754 binary32 / binary64 decode (big-endian).
local function f32(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    local sign = (b1 >= 128) and -1 or 1
    local exp  = ((b1 % 128) * 2) + (b2 // 128)
    local mant = ((b2 % 128) * 65536) + (b3 * 256) + b4
    if exp == 0xFF then
        if mant == 0 then return sign * math.huge end
        return 0/0
    end
    if exp == 0 then
        return sign * (mant / 0x800000) * 2 ^ -126
    end
    return sign * (1 + mant / 0x800000) * 2 ^ (exp - 127)
end

local function f64(s, i)
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(i, i + 7)
    local sign = (b1 >= 128) and -1 or 1
    local exp  = ((b1 % 128) * 16) + (b2 // 16)
    local mant_hi = b2 % 16
    local mant_lo = (b3 * 256 ^ 4) + (b4 * 256 ^ 3) + (b5 * 256 ^ 2) + (b6 * 256) + b7
    -- 7 bytes used (b3..b8 is 6 bytes plus mant_hi nibble). recompute:
    mant_lo = (b3 * 2 ^ 40) + (b4 * 2 ^ 32) + (b5 * 2 ^ 24) + (b6 * 2 ^ 16) + (b7 * 2 ^ 8) + b8
    local mant = mant_hi * 2 ^ 48 + mant_lo
    if exp == 0x7FF then
        if mant == 0 then return sign * math.huge end
        return 0/0
    end
    if exp == 0 then
        return sign * (mant / 2 ^ 52) * 2 ^ -1022
    end
    return sign * (1 + mant / 2 ^ 52) * 2 ^ (exp - 1023)
end

-- ===== IP parsing ======================================================

local function parse_ipv4(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return { a, b, c, d }
end

local function parse_ipv6(ip)
    -- IPv4-mapped IPv6 (::ffff:1.2.3.4) is handled by the lookup wrapper.
    local left, right = ip:match("^(.-)::(.+)$")
    local parts = {}
    local function push_hexgroup(g)
        if g == "" then return end
        parts[#parts + 1] = tonumber(g, 16)
    end
    if left or right then
        -- "::" present
        left  = left or ""
        right = right or ""
        local lp, rp = {}, {}
        for g in left:gmatch("[^:]+") do lp[#lp + 1] = tonumber(g, 16) end
        for g in right:gmatch("[^:]+") do rp[#rp + 1] = tonumber(g, 16) end
        local missing = 8 - #lp - #rp
        if missing < 0 then return nil end
        for _, v in ipairs(lp) do parts[#parts + 1] = v end
        for _ = 1, missing do parts[#parts + 1] = 0 end
        for _, v in ipairs(rp) do parts[#parts + 1] = v end
    elseif ip:find("::", 1, true) then
        return nil
    else
        for g in ip:gmatch("[^:]+") do push_hexgroup(g) end
    end
    if #parts ~= 8 then return nil end
    local bytes = {}
    for i = 1, 8 do
        local v = parts[i]
        if not v or v < 0 or v > 0xFFFF then return nil end
        bytes[#bytes + 1] = v // 256
        bytes[#bytes + 1] = v % 256
    end
    return bytes
end

local function ip_to_bytes(ip)
    if ip:find(":", 1, true) then
        return parse_ipv6(ip), 16
    else
        return parse_ipv4(ip), 4
    end
end

-- ===== Data section decoder ============================================
--
-- Control byte layout:
--   bits 7..5 = type tag (1..7)
--             0 -> extended type follows; real_type = next_byte + 7
--   bits 4..0 = size
--             0..28 -> direct size
--             29     -> 1 extra size byte, size = byte + 29
--             30     -> 2 extra size bytes, size = u16 + 285
--             31     -> 3 extra size bytes, size = u24 + 65821
-- Type tags:
--   1 pointer   2 utf8 string   3 double   4 bytes   5 uint16   6 uint32
--   7 map       (ext) 8 int32   9 uint64  10 uint128  11 array
--               12 container 13 end-marker 14 boolean 15 float

local Reader = {}
Reader.__index = Reader

local function decode_pointer(self, ctrl, pos)
    local size = (ctrl >> 3) & 0x3
    local lower = ctrl & 0x7
    local s = self._data
    if size == 0 then
        local b = u8(s, pos + 1)
        return lower * 256 + b, pos + 2
    elseif size == 1 then
        local b1, b2 = u8(s, pos + 1), u8(s, pos + 2)
        return 2048 + lower * 65536 + b1 * 256 + b2, pos + 3
    elseif size == 2 then
        local b1, b2, b3 = u8(s, pos + 1), u8(s, pos + 2), u8(s, pos + 3)
        return 526336 + lower * 16777216 + b1 * 65536 + b2 * 256 + b3, pos + 4
    else
        -- size == 3
        return u32(s, pos + 1), pos + 5
    end
end

local decode_value

local function decode_size(ctrl, s, pos)
    -- Returns size, pos_after_size_bytes (pos was at the first byte after ctrl)
    local size = ctrl & 0x1F
    if size < 29 then return size, pos end
    if size == 29 then return u8(s, pos) + 29, pos + 1 end
    if size == 30 then return u16(s, pos) + 285, pos + 2 end
    return u24(s, pos) + 65821, pos + 3
end

decode_value = function(self, pos)
    local s = self._data
    local ctrl = u8(s, pos)
    local typ = ctrl >> 5
    pos = pos + 1
    if typ == 0 then
        -- extended
        typ = u8(s, pos) + 7
        pos = pos + 1
    end

    if typ == 1 then
        -- pointer (size+value computed jointly with ctrl)
        local target, next_pos = decode_pointer(self, ctrl, pos - 1)
        local data_start = self._data_section_start
        local v = decode_value(self, data_start + target)
        return v, next_pos
    end

    local size
    size, pos = decode_size(ctrl, s, pos)

    if typ == 2 then
        -- utf8 string
        return s:sub(pos, pos + size - 1), pos + size
    elseif typ == 3 then
        return f64(s, pos), pos + size  -- size = 8
    elseif typ == 4 then
        return s:sub(pos, pos + size - 1), pos + size  -- raw bytes
    elseif typ == 5 then
        return uN(s, pos, size), pos + size  -- uint16
    elseif typ == 6 then
        return uN(s, pos, size), pos + size  -- uint32
    elseif typ == 7 then
        -- map; size = number of key/value pairs
        local m = {}
        for _ = 1, size do
            local k, v
            k, pos = decode_value(self, pos)
            v, pos = decode_value(self, pos)
            m[k] = v
        end
        return m, pos
    elseif typ == 8 then
        -- int32 (signed). values are big-endian, leading sign bit.
        local v = uN(s, pos, size)
        if size == 4 and v >= 0x80000000 then v = v - 0x100000000 end
        return v, pos + size
    elseif typ == 9 then
        return uN(s, pos, size), pos + size  -- uint64
    elseif typ == 10 then
        -- uint128 -- return as hex string (Lua has no native 128-bit)
        return ("%s"):format(s:sub(pos, pos + size - 1):gsub(".", function(c)
            return ("%02x"):format(c:byte())
        end)), pos + size
    elseif typ == 11 then
        -- array
        local a = {}
        for i = 1, size do
            local v
            v, pos = decode_value(self, pos)
            a[i] = v
        end
        return a, pos
    elseif typ == 12 then
        -- container -- not used in current MMDB format
        return nil, pos + size
    elseif typ == 13 then
        return nil, pos  -- end marker
    elseif typ == 14 then
        return size ~= 0, pos  -- boolean
    elseif typ == 15 then
        return f32(s, pos), pos + size  -- float
    else
        error("geoip: unknown type tag " .. typ)
    end
end

-- ===== Tree walk =======================================================

local function read_node(self, node_index, side)
    -- Records are bit-packed. Two cases handled:
    --   24-bit records (record_size = 24): 6 bytes per node, trivial.
    --   28-bit records (record_size = 28): 7 bytes per node; the 4 high
    --     bits of the middle byte hold the high nibble of the LEFT record
    --     in its high nibble, and high nibble of the RIGHT record in its
    --     low nibble.
    --   32-bit records (record_size = 32): 8 bytes per node, trivial.
    local rs = self._record_size
    local s  = self._data
    local node_size = rs * 2 // 8
    local off = node_index * node_size + 1
    if rs == 24 then
        if side == 0 then
            return u24(s, off)
        else
            return u24(s, off + 3)
        end
    elseif rs == 28 then
        local mid = u8(s, off + 3)
        if side == 0 then
            return ((mid >> 4) & 0xF) * 0x1000000 + u24(s, off)
        else
            return (mid & 0xF) * 0x1000000 + u24(s, off + 4)
        end
    elseif rs == 32 then
        if side == 0 then
            return u32(s, off)
        else
            return u32(s, off + 4)
        end
    else
        error("geoip: unsupported record_size " .. rs)
    end
end

local function bytes_to_bits(bytes)
    local bits = {}
    for i = 1, #bytes do
        local b = bytes[i]
        for j = 7, 0, -1 do
            bits[#bits + 1] = (b >> j) & 1
        end
    end
    return bits
end

function Reader:lookup(ip)
    local bytes, family = ip_to_bytes(ip)
    if not bytes then return nil, "bad ip" end

    local node = 0
    local node_count = self._node_count
    local ip_version = self._metadata.ip_version

    -- IPv4 inside an IPv6 db: walk first 96 bits as zero, then the v4 bits.
    -- Spec: the standard tree handles this automatically via the IPv4
    -- subtree-root. The simple correct approach is to feed 96 leading zero
    -- bits before the v4 bytes when the DB is v6.
    local bits
    if family == 4 and ip_version == 6 then
        local zeros = {}
        for i = 1, 96 do zeros[i] = 0 end
        local v4_bits = bytes_to_bits(bytes)
        for _, b in ipairs(v4_bits) do zeros[#zeros + 1] = b end
        bits = zeros
    else
        bits = bytes_to_bits(bytes)
    end

    for i = 1, #bits do
        if node >= node_count then break end
        node = read_node(self, node, bits[i])
    end

    if node == node_count then
        return nil  -- empty / no-record sentinel
    elseif node > node_count then
        -- node points into the data section.
        -- pointer offset = node - node_count - 16
        local data_off = (node - node_count - 16) + self._data_section_start
        local v = decode_value(self, data_off)
        return v
    end
    -- Walked off the tree without resolving.
    return nil
end

function Reader:metadata()
    return self._metadata
end

function Reader:close()
    self._data = nil
end

-- ===== open() ==========================================================

local function find_metadata(data)
    -- Search from the end. Spec says marker appears only once.
    local marker_len = #METADATA_MARKER
    local n = #data
    -- last 128 KiB is enough per the spec but we allow full scan as fallback.
    local start = math.max(1, n - (128 * 1024))
    for i = n - marker_len, start, -1 do
        if data:sub(i, i + marker_len - 1) == METADATA_MARKER then
            return i + marker_len
        end
    end
    -- Slow fallback (shouldn't happen in practice).
    local i = data:find(METADATA_MARKER, 1, true)
    if i then return i + marker_len end
    return nil
end

function M.open(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()

    local meta_start = find_metadata(data)
    if not meta_start then
        return nil, "geoip: metadata marker not found"
    end

    local tmp = setmetatable({
        _data = data,
        _data_section_start = 1,  -- temporarily, for metadata decode
    }, Reader)

    local metadata = decode_value(tmp, meta_start)
    if type(metadata) ~= "table" then
        return nil, "geoip: bad metadata block"
    end

    local node_count  = metadata.node_count
    local record_size = metadata.record_size
    local tree_size   = node_count * record_size * 2 // 8

    local self = setmetatable({
        _data               = data,
        _node_count         = node_count,
        _record_size        = record_size,
        _data_section_start = tree_size + 16 + 1,  -- 16 zero bytes separator; +1 for 1-based
        _metadata           = metadata,
    }, Reader)

    return self
end

return M
