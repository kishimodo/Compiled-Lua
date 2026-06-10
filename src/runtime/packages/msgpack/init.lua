-- msgpack -- MessagePack encoder / decoder.
--
-- Public surface:
--   msgpack.pack(value)            -> string
--   msgpack.unpack(bytes, pos?)    -> value, next_pos
--   msgpack.unpack_all(bytes)      -> { values }
--   msgpack.register_ext(id, encoder_fn, decoder_fn)
--   msgpack.nil_value              -- sentinel for explicit nil
--   msgpack.ext(type_id, data)     -- wrap raw ext payload
--
-- Wire spec: https://github.com/msgpack/msgpack/blob/master/spec.md
-- All multi-byte integers are big-endian.

local M = {}

local char  = string.char
local byte  = string.byte
local sub   = string.sub
local concat= table.concat
local floor = math.floor
local huge  = math.huge

-- Sentinel for explicit nil (distinguishes a present-but-nil from absent).
local _nil = setmetatable({}, { __tostring = function() return "msgpack.nil" end })
M.nil_value = _nil

-- Wrap raw ext payloads so they round-trip through pack/unpack.
local _ext_mt = {}
function M.ext(type_id, data)
    return setmetatable({ type = type_id, data = data }, _ext_mt)
end

local _ext_encoders = {}  -- [lua_meta] = function(v) -> type_id, data_string
local _ext_decoders = {}  -- [type_id]  = function(data_string) -> value

function M.register_ext(type_id, encoder, decoder)
    if type(type_id) ~= "number" or type_id < -128 or type_id > 127 then
        error("msgpack.register_ext: type_id must be in [-128,127]")
    end
    if encoder then _ext_encoders[#_ext_encoders + 1] = { id = type_id, fn = encoder } end
    if decoder then _ext_decoders[type_id] = decoder end
end

-- Big-endian unsigned writers.
local function w_u8(n)  return char(n & 0xFF) end
local function w_u16(n) return char((n >> 8) & 0xFF, n & 0xFF) end
local function w_u32(n)
    return char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end
local function w_u64(n)
    -- Lua integers are 64-bit on the runtime; treat as unsigned bit pattern.
    return char(
        (n >> 56) & 0xFF, (n >> 48) & 0xFF, (n >> 40) & 0xFF, (n >> 32) & 0xFF,
        (n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >>  8) & 0xFF,  n        & 0xFF)
end

local function encode_int(n, buf, bn)
    if n >= 0 then
        if n <= 0x7F then
            bn = bn + 1; buf[bn] = char(n)
        elseif n <= 0xFF then
            bn = bn + 1; buf[bn] = "\xCC" .. w_u8(n)
        elseif n <= 0xFFFF then
            bn = bn + 1; buf[bn] = "\xCD" .. w_u16(n)
        elseif n <= 0xFFFFFFFF then
            bn = bn + 1; buf[bn] = "\xCE" .. w_u32(n)
        else
            bn = bn + 1; buf[bn] = "\xCF" .. w_u64(n)
        end
    else
        if n >= -32 then
            bn = bn + 1; buf[bn] = char(0xE0 | (n + 32))
        elseif n >= -0x80 then
            bn = bn + 1; buf[bn] = "\xD0" .. w_u8(n & 0xFF)
        elseif n >= -0x8000 then
            bn = bn + 1; buf[bn] = "\xD1" .. w_u16(n & 0xFFFF)
        elseif n >= -0x80000000 then
            bn = bn + 1; buf[bn] = "\xD2" .. w_u32(n & 0xFFFFFFFF)
        else
            bn = bn + 1; buf[bn] = "\xD3" .. w_u64(n)
        end
    end
    return bn
end

-- IEEE-754 binary64 -- canonical exact codec via string.pack(">d", n).
-- The 0xCB format byte frames an 8-byte big-endian binary64 payload.
local function encode_double(n)
    return "\xCB" .. string.pack(">d", n)
end

local function is_array(t)
    local n = #t
    if n == 0 then
        return next(t) == nil  -- empty -> treat as empty array
    end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        if k ~= floor(k) or k < 1 or k > n then return false end
        count = count + 1
    end
    return count == n
end

local encode_value
encode_value = function(v, buf, bn)
    if v == nil or v == _nil then
        bn = bn + 1; buf[bn] = "\xC0"
        return bn
    end
    local mt = getmetatable(v)
    if mt == _ext_mt then
        local data = v.data
        local len = #data
        local id = v.type & 0xFF
        if     len == 1  then bn = bn + 1; buf[bn] = "\xD4" .. char(id) .. data
        elseif len == 2  then bn = bn + 1; buf[bn] = "\xD5" .. char(id) .. data
        elseif len == 4  then bn = bn + 1; buf[bn] = "\xD6" .. char(id) .. data
        elseif len == 8  then bn = bn + 1; buf[bn] = "\xD7" .. char(id) .. data
        elseif len == 16 then bn = bn + 1; buf[bn] = "\xD8" .. char(id) .. data
        elseif len <= 0xFF       then bn = bn + 1; buf[bn] = "\xC7" .. w_u8(len)  .. char(id) .. data
        elseif len <= 0xFFFF     then bn = bn + 1; buf[bn] = "\xC8" .. w_u16(len) .. char(id) .. data
        else                          bn = bn + 1; buf[bn] = "\xC9" .. w_u32(len) .. char(id) .. data
        end
        return bn
    end
    -- Try registered ext encoders by metatable identity.
    if mt then
        for i = 1, #_ext_encoders do
            local entry = _ext_encoders[i]
            if entry.meta == mt then
                local data = entry.fn(v)
                return encode_value(M.ext(entry.id, data), buf, bn)
            end
        end
    end
    local t = type(v)
    if t == "boolean" then
        bn = bn + 1; buf[bn] = v and "\xC3" or "\xC2"
    elseif t == "number" then
        if math.type and math.type(v) == "integer" then
            bn = encode_int(v, buf, bn)
        elseif v == floor(v) and v >= -0x8000000000000000 and v <= 0x7FFFFFFFFFFFFFFF then
            bn = encode_int(v, buf, bn)
        else
            bn = bn + 1; buf[bn] = encode_double(v)
        end
    elseif t == "string" then
        local len = #v
        if     len <= 31         then bn = bn + 1; buf[bn] = char(0xA0 | len) .. v
        elseif len <= 0xFF       then bn = bn + 1; buf[bn] = "\xD9" .. w_u8(len)  .. v
        elseif len <= 0xFFFF     then bn = bn + 1; buf[bn] = "\xDA" .. w_u16(len) .. v
        else                          bn = bn + 1; buf[bn] = "\xDB" .. w_u32(len) .. v
        end
    elseif t == "table" then
        if is_array(v) then
            local n = #v
            if     n <= 15       then bn = bn + 1; buf[bn] = char(0x90 | n)
            elseif n <= 0xFFFF   then bn = bn + 1; buf[bn] = "\xDC" .. w_u16(n)
            else                      bn = bn + 1; buf[bn] = "\xDD" .. w_u32(n)
            end
            for i = 1, n do bn = encode_value(v[i], buf, bn) end
        else
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            if     n <= 15       then bn = bn + 1; buf[bn] = char(0x80 | n)
            elseif n <= 0xFFFF   then bn = bn + 1; buf[bn] = "\xDE" .. w_u16(n)
            else                      bn = bn + 1; buf[bn] = "\xDF" .. w_u32(n)
            end
            for k, val in pairs(v) do
                bn = encode_value(k, buf, bn)
                bn = encode_value(val, buf, bn)
            end
        end
    else
        error("msgpack.pack: unsupported type " .. t)
    end
    return bn
end

function M.pack(value)
    local buf = {}
    encode_value(value, buf, 0)
    return concat(buf)
end

-- ===== Decode ==========================================================

local function r_u8(s, p)
    return byte(s, p), p + 1
end
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
local function r_i8(s, p)
    local v = byte(s, p); if v >= 0x80 then v = v - 0x100 end
    return v, p + 1
end
local function r_i16(s, p)
    local v, q = r_u16(s, p); if v >= 0x8000 then v = v - 0x10000 end
    return v, q
end
local function r_i32(s, p)
    local v, q = r_u32(s, p); if v >= 0x80000000 then v = v - 0x100000000 end
    return v, q
end
local function r_i64(s, p)
    -- Reuse u64 bit pattern; Lua's signed 64-bit math handles sign naturally.
    local a, b, c, d, e, f, g, h = byte(s, p, p + 7)
    local hi = (a << 24) | (b << 16) | (c << 8) | d
    local lo = (e << 24) | (f << 16) | (g << 8) | h
    if hi >= 0x80000000 then hi = hi - 0x100000000 end
    return (hi * 0x100000000) + lo, p + 8
end

local function r_f32(s, p)
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

local function r_f64(s, p)
    -- Canonical exact decode of the 8-byte big-endian binary64 payload.
    local v = string.unpack(">d", s, p)
    return v, p + 8
end

local decode_value

local function decode_array(s, p, n)
    local arr = {}
    for i = 1, n do
        arr[i], p = decode_value(s, p)
    end
    return arr, p
end

local function decode_map(s, p, n)
    local m = {}
    for _ = 1, n do
        local k, v
        k, p = decode_value(s, p)
        v, p = decode_value(s, p)
        m[k] = v
    end
    return m, p
end

local function decode_ext(s, p, len)
    local id; id, p = r_i8(s, p)
    local data = sub(s, p, p + len - 1)
    p = p + len
    local dec = _ext_decoders[id]
    if dec then return dec(data), p end
    return M.ext(id, data), p
end

decode_value = function(s, p)
    local b = byte(s, p); p = p + 1
    if b < 0x80 then  -- positive fixint
        return b, p
    elseif b >= 0xE0 then  -- negative fixint
        return b - 0x100, p
    elseif b >= 0xA0 and b <= 0xBF then  -- fixstr
        local len = b - 0xA0
        return sub(s, p, p + len - 1), p + len
    elseif b >= 0x90 and b <= 0x9F then  -- fixarray
        return decode_array(s, p, b - 0x90)
    elseif b >= 0x80 and b <= 0x8F then  -- fixmap
        return decode_map(s, p, b - 0x80)
    end
    if     b == 0xC0 then return nil, p
    elseif b == 0xC2 then return false, p
    elseif b == 0xC3 then return true,  p
    elseif b == 0xC4 then  -- bin8
        local len; len, p = r_u8(s, p)
        return sub(s, p, p + len - 1), p + len
    elseif b == 0xC5 then  -- bin16
        local len; len, p = r_u16(s, p)
        return sub(s, p, p + len - 1), p + len
    elseif b == 0xC6 then  -- bin32
        local len; len, p = r_u32(s, p)
        return sub(s, p, p + len - 1), p + len
    elseif b == 0xC7 then  -- ext8
        local len; len, p = r_u8(s, p); return decode_ext(s, p, len)
    elseif b == 0xC8 then  -- ext16
        local len; len, p = r_u16(s, p); return decode_ext(s, p, len)
    elseif b == 0xC9 then  -- ext32
        local len; len, p = r_u32(s, p); return decode_ext(s, p, len)
    elseif b == 0xCA then return r_f32(s, p)
    elseif b == 0xCB then return r_f64(s, p)
    elseif b == 0xCC then return r_u8(s, p)
    elseif b == 0xCD then return r_u16(s, p)
    elseif b == 0xCE then return r_u32(s, p)
    elseif b == 0xCF then return r_u64(s, p)
    elseif b == 0xD0 then return r_i8(s, p)
    elseif b == 0xD1 then return r_i16(s, p)
    elseif b == 0xD2 then return r_i32(s, p)
    elseif b == 0xD3 then return r_i64(s, p)
    elseif b == 0xD4 then return decode_ext(s, p, 1)
    elseif b == 0xD5 then return decode_ext(s, p, 2)
    elseif b == 0xD6 then return decode_ext(s, p, 4)
    elseif b == 0xD7 then return decode_ext(s, p, 8)
    elseif b == 0xD8 then return decode_ext(s, p, 16)
    elseif b == 0xD9 then  -- str8
        local len; len, p = r_u8(s, p)
        return sub(s, p, p + len - 1), p + len
    elseif b == 0xDA then  -- str16
        local len; len, p = r_u16(s, p)
        return sub(s, p, p + len - 1), p + len
    elseif b == 0xDB then  -- str32
        local len; len, p = r_u32(s, p)
        return sub(s, p, p + len - 1), p + len
    elseif b == 0xDC then  -- array16
        local len; len, p = r_u16(s, p)
        return decode_array(s, p, len)
    elseif b == 0xDD then  -- array32
        local len; len, p = r_u32(s, p)
        return decode_array(s, p, len)
    elseif b == 0xDE then  -- map16
        local len; len, p = r_u16(s, p)
        return decode_map(s, p, len)
    elseif b == 0xDF then  -- map32
        local len; len, p = r_u32(s, p)
        return decode_map(s, p, len)
    end
    error(string.format("msgpack.unpack: unknown tag 0x%02X at %d", b, p - 1))
end

function M.unpack(bytes, pos)
    return decode_value(bytes, pos or 1)
end

function M.unpack_all(bytes)
    local out, p, n = {}, 1, 0
    local len = #bytes
    while p <= len do
        local v
        v, p = decode_value(bytes, p)
        n = n + 1; out[n] = v
    end
    return out
end

return M
