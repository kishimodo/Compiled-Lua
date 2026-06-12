-- cbor -- RFC 8949 (Concise Binary Object Representation).
--
-- Public surface:
--   cbor.encode(v)                     -> string
--   cbor.decode(bytes, pos?)           -> value, next_pos
--   cbor.decode_stream(reader)         -> iterator: each call returns next value
--   cbor.tag(number, value)            -> wrapped tagged value (round-trips)
--   cbor.simple(n)                     -> simple value (0..255)
--   cbor.null, cbor.undef              -> CBOR null / undefined sentinels
--   cbor.bytes(s)                      -> mark a string as bytes (major type 2)
--
-- The encoder picks the smallest valid representation for ints and uses
-- IEEE 754 binary64 for floats (binary16/32 only emitted on round-trip
-- when explicitly requested via cbor.float16(n) or cbor.float32(n)).

local M = {}

local char  = string.char
local byte  = string.byte
local sub   = string.sub
local concat= table.concat
local floor = math.floor
local huge  = math.huge

-- Sentinels (simple values 22/23 in CBOR vocabulary).
local _null  = setmetatable({}, { __tostring = function() return "cbor.null" end })
local _undef = setmetatable({}, { __tostring = function() return "cbor.undef" end })
M.null, M.undef = _null, _undef

-- Tagged value wrapper.
local _tag_mt = {}
function M.tag(tag, value)
    return setmetatable({ tag = tag, value = value }, _tag_mt)
end

-- Simple value (5-bit immediate or 0xF8 + byte).
local _simple_mt = {}
function M.simple(n)
    if n < 0 or n > 255 then error("cbor.simple: out of range") end
    return setmetatable({ value = n }, _simple_mt)
end

-- Byte-string marker (major type 2 instead of 3).
local _bytes_mt = {}
function M.bytes(s)
    return setmetatable({ data = s }, _bytes_mt)
end

-- Float-width hints (force binary16 / binary32 emit).
local _f16_mt, _f32_mt = {}, {}
function M.float16(n) return setmetatable({ value = n }, _f16_mt) end
function M.float32(n) return setmetatable({ value = n }, _f32_mt) end

-- Indefinite-length sentinel for break (0xFF).
local _break = {}

-- Big-endian writers.
local function w_u8(n)  return char(n & 0xFF) end
local function w_u16(n) return char((n >> 8) & 0xFF, n & 0xFF) end
local function w_u32(n)
    return char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end
local function w_u64(n)
    return char(
        (n >> 56) & 0xFF, (n >> 48) & 0xFF, (n >> 40) & 0xFF, (n >> 32) & 0xFF,
        (n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >>  8) & 0xFF,  n        & 0xFF)
end

-- Major-type header (mt 0..7) with shortest argument encoding for n.
local function w_head(mt, n)
    local base = mt << 5
    if     n <= 23          then return char(base | n)
    elseif n <= 0xFF        then return char(base | 24) .. w_u8(n)
    elseif n <= 0xFFFF      then return char(base | 25) .. w_u16(n)
    elseif n <= 0xFFFFFFFF  then return char(base | 26) .. w_u32(n)
    else                         return char(base | 27) .. w_u64(n)
    end
end

local function encode_float64(n)
    return char(0xFB) .. string.pack(">d", n)
end

local function encode_float32(n)
    if n ~= n then return "\xFA\x7F\xC0\x00\x00" end
    if n == huge then return "\xFA\x7F\x80\x00\x00" end
    if n == -huge then return "\xFA\xFF\x80\x00\x00" end
    if n == 0 then
        local sign = (1 / n == -huge) and 0x80 or 0x00
        return char(0xFA, sign, 0, 0, 0)
    end
    local sign = 0
    if n < 0 then sign = 0x80; n = -n end
    local m, e = math.frexp(n)
    e = e - 1; m = m * 2 - 1; e = e + 127
    if e <= 0 then
        m = (m + 1) * 0.5 * 2 ^ (e + 23); e = 0
    else
        m = m * 2 ^ 23
    end
    local mi = floor(m + 0.5)
    return char(0xFA,
        sign | ((e >> 1) & 0x7F),
        ((e & 1) << 7) | ((mi >> 16) & 0x7F),
        (mi >> 8) & 0xFF,
         mi       & 0xFF)
end

local function encode_float16(n)
    -- IEEE 754 binary16: 1 sign, 5 exp (bias 15), 10 mantissa.
    if n ~= n then return "\xF9\x7E\x00" end
    if n == huge then return "\xF9\x7C\x00" end
    if n == -huge then return "\xF9\xFC\x00" end
    if n == 0 then
        local sign = (1 / n == -huge) and 0x80 or 0x00
        return char(0xF9, sign, 0)
    end
    local sign = 0
    if n < 0 then sign = 0x80; n = -n end
    local m, e = math.frexp(n)
    e = e - 1; m = m * 2 - 1; e = e + 15
    if e <= 0 then
        m = (m + 1) * 0.5 * 2 ^ (e + 10); e = 0
    elseif e >= 31 then
        return char(0xF9, sign | 0x7C, 0)  -- overflow -> Inf
    else
        m = m * 2 ^ 10
    end
    local mi = floor(m + 0.5)
    return char(0xF9,
        sign | ((e << 2) & 0x7C) | ((mi >> 8) & 0x03),
        mi & 0xFF)
end

local function is_array(t)
    local n = #t
    if n == 0 then return next(t) == nil end
    local c = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        if k ~= floor(k) or k < 1 or k > n then return false end
        c = c + 1
    end
    return c == n
end

local encode_value
encode_value = function(v, buf, bn)
    if v == nil or v == _null then
        bn = bn + 1; buf[bn] = "\xF6"; return bn
    end
    if v == _undef then
        bn = bn + 1; buf[bn] = "\xF7"; return bn
    end
    local mt = getmetatable(v)
    if mt == _tag_mt then
        bn = bn + 1; buf[bn] = w_head(6, v.tag)
        return encode_value(v.value, buf, bn)
    elseif mt == _simple_mt then
        local n = v.value
        if n < 24 then bn = bn + 1; buf[bn] = char(0xE0 | n)
        else           bn = bn + 1; buf[bn] = char(0xF8) .. w_u8(n)
        end
        return bn
    elseif mt == _bytes_mt then
        bn = bn + 1; buf[bn] = w_head(2, #v.data) .. v.data
        return bn
    elseif mt == _f16_mt then
        bn = bn + 1; buf[bn] = encode_float16(v.value); return bn
    elseif mt == _f32_mt then
        bn = bn + 1; buf[bn] = encode_float32(v.value); return bn
    end
    local t = type(v)
    if t == "boolean" then
        bn = bn + 1; buf[bn] = v and "\xF5" or "\xF4"
    elseif t == "number" then
        if math.type and math.type(v) == "integer" then
            if v >= 0 then bn = bn + 1; buf[bn] = w_head(0, v)
            else           bn = bn + 1; buf[bn] = w_head(1, -1 - v)
            end
        elseif v == floor(v) and v >= -0x8000000000000000 and v <= 0x7FFFFFFFFFFFFFFF then
            if v >= 0 then bn = bn + 1; buf[bn] = w_head(0, v)
            else           bn = bn + 1; buf[bn] = w_head(1, -1 - v)
            end
        else
            bn = bn + 1; buf[bn] = encode_float64(v)
        end
    elseif t == "string" then
        bn = bn + 1; buf[bn] = w_head(3, #v) .. v
    elseif t == "table" then
        if is_array(v) then
            local n = #v
            bn = bn + 1; buf[bn] = w_head(4, n)
            for i = 1, n do bn = encode_value(v[i], buf, bn) end
        else
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            bn = bn + 1; buf[bn] = w_head(5, n)
            for k, val in pairs(v) do
                bn = encode_value(k, buf, bn)
                bn = encode_value(val, buf, bn)
            end
        end
    else
        error("cbor.encode: unsupported type " .. t)
    end
    return bn
end

function M.encode(v)
    local buf = {}
    encode_value(v, buf, 0)
    return concat(buf)
end

-- ===== Decode ==========================================================

local function r_u8 (s, p) return byte(s, p), p + 1 end
local function r_u16(s, p)
    local a, b = byte(s, p, p + 1)
    return (a << 8) | b, p + 2
end
local function r_u32(s, p)
    local a, b, c, d = byte(s, p, p + 3)
    return (a << 24) | (b << 16) | (c << 8) | d, p + 4
end
local function r_u64(s, p)
    local a, b, c, d, e, f, g, h = byte(s, p, p + 7)
    return (a << 56) | (b << 48) | (c << 40) | (d << 32)
         | (e << 24) | (f << 16) | (g <<  8) | h, p + 8
end

local function read_arg(ai, s, p)
    if ai < 24 then return ai, p
    elseif ai == 24 then return r_u8(s, p)
    elseif ai == 25 then return r_u16(s, p)
    elseif ai == 26 then return r_u32(s, p)
    elseif ai == 27 then return r_u64(s, p)
    end
    return nil, p
end

local function read_f16(s, p)
    local b0, b1 = byte(s, p, p + 1)
    local sign = (b0 >= 0x80) and -1 or 1
    local exp  = (b0 & 0x7C) >> 2
    local mant = ((b0 & 0x03) << 8) | b1
    if exp == 0 then
        if mant == 0 then return sign * 0, p + 2 end
        return sign * math.ldexp(mant, -24), p + 2
    elseif exp == 0x1F then
        if mant == 0 then return sign * huge, p + 2 end
        return 0 / 0, p + 2
    end
    return sign * math.ldexp(mant + 1024, exp - 25), p + 2
end

local function read_f32(s, p)
    local b0, b1, b2, b3 = byte(s, p, p + 3)
    local sign = (b0 >= 0x80) and -1 or 1
    local exp  = ((b0 & 0x7F) << 1) | (b1 >> 7)
    local mant = ((b1 & 0x7F) << 16) | (b2 << 8) | b3
    if exp == 0xFF then
        if mant == 0 then return sign * huge, p + 4 end
        return 0 / 0, p + 4
    elseif exp == 0 then
        if mant == 0 then return sign * 0, p + 4 end
        return sign * math.ldexp(mant, -149), p + 4
    end
    return sign * math.ldexp(mant + 0x800000, exp - 150), p + 4
end

local function read_f64(s, p)
    local v = string.unpack(">d", s, p)
    return v, p + 8
end

local decode_value

local function decode_indef_string(s, p, want_mt)
    local parts, np = {}, 0
    while true do
        local b = byte(s, p)
        if b == 0xFF then return concat(parts), p + 1 end
        local m, a = b >> 5, b & 0x1F
        if m ~= want_mt or a == 31 then error("cbor: bad indefinite chunk") end
        local len; len, p = read_arg(a, s, p + 1)
        np = np + 1; parts[np] = sub(s, p, p + len - 1)
        p = p + len
    end
end

decode_value = function(s, p)
    local b = byte(s, p); p = p + 1
    local mt = b >> 5
    local ai = b & 0x1F
    if mt == 0 then
        local n; n, p = read_arg(ai, s, p)
        return n, p
    elseif mt == 1 then
        local n; n, p = read_arg(ai, s, p)
        return -1 - n, p
    elseif mt == 2 then
        if ai == 31 then
            local v; v, p = decode_indef_string(s, p, 2)
            return M.bytes(v), p
        end
        local len; len, p = read_arg(ai, s, p)
        return M.bytes(sub(s, p, p + len - 1)), p + len
    elseif mt == 3 then
        if ai == 31 then return decode_indef_string(s, p, 3) end
        local len; len, p = read_arg(ai, s, p)
        return sub(s, p, p + len - 1), p + len
    elseif mt == 4 then
        local arr = {}
        if ai == 31 then
            local n = 0
            while byte(s, p) ~= 0xFF do
                n = n + 1; arr[n], p = decode_value(s, p)
            end
            return arr, p + 1
        end
        local len; len, p = read_arg(ai, s, p)
        for i = 1, len do arr[i], p = decode_value(s, p) end
        return arr, p
    elseif mt == 5 then
        local m = {}
        if ai == 31 then
            while byte(s, p) ~= 0xFF do
                local k, v
                k, p = decode_value(s, p)
                v, p = decode_value(s, p)
                m[k] = v
            end
            return m, p + 1
        end
        local len; len, p = read_arg(ai, s, p)
        for _ = 1, len do
            local k, v
            k, p = decode_value(s, p)
            v, p = decode_value(s, p)
            m[k] = v
        end
        return m, p
    elseif mt == 6 then
        local tag; tag, p = read_arg(ai, s, p)
        local val; val, p = decode_value(s, p)
        return M.tag(tag, val), p
    elseif mt == 7 then
        if ai < 24 then
            if     ai == 20 then return false, p
            elseif ai == 21 then return true,  p
            elseif ai == 22 then return _null, p
            elseif ai == 23 then return _undef, p
            end
            return M.simple(ai), p
        elseif ai == 24 then
            local n; n, p = r_u8(s, p)
            return M.simple(n), p
        elseif ai == 25 then return read_f16(s, p)
        elseif ai == 26 then return read_f32(s, p)
        elseif ai == 27 then return read_f64(s, p)
        elseif ai == 31 then return _break, p
        end
    end
    error(string.format("cbor: unsupported initial byte 0x%02X", b))
end

function M.decode(bytes, pos)
    return decode_value(bytes, pos or 1)
end

function M.decode_stream(reader)
    -- reader: callable returning successive string chunks (or nil at EOF).
    -- We accumulate lazily; the iterator returns one top-level value per call.
    local buf, p = "", 1
    local function pump()
        local chunk = reader()
        if chunk == nil then return false end
        buf = sub(buf, p) .. chunk
        p = 1
        return true
    end
    return function()
        while p > #buf do
            if not pump() then return nil end
        end
        local v, np = decode_value(buf, p)
        p = np
        return v
    end
end

return M
