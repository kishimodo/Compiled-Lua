-- varint -- LEB128 / protobuf varints.
--
-- Public surface:
--   varint.encode_uint(n)         -> string
--   varint.decode_uint(s, pos?)   -> value, next_pos
--   varint.encode_sint(n)         -> string   (zigzag)
--   varint.decode_sint(s, pos?)   -> value, next_pos   (zigzag)
--   varint.size_uint(n)           -> number of bytes the encoding would take
--
-- Bit layout: low 7 bits are payload, MSB is "more bytes follow". Encoding
-- uses Lua 5.4 64-bit integer arithmetic; values are treated as unsigned
-- with the standard two's-complement bit pattern.

local M = {}

function M.encode_uint(n)
    if type(n) ~= "number" then
        error("varint.encode_uint: expected number, got " .. type(n))
    end
    if math.type and math.type(n) ~= "integer" then
        if n ~= math.floor(n) then
            error("varint.encode_uint: non-integer value")
        end
        n = math.tointeger(n)
    end
    -- Handle zero up front so the loop logic stays simple.
    if n == 0 then return "\0" end
    local out, k = {}, 0
    while true do
        local byte = n & 0x7F
        -- Logical shift right by 7. For negative values (treated as uint64) this is
        -- a logical right shift courtesy of Lua's >> on integers.
        n = n >> 7
        if n == 0 then
            k = k + 1; out[k] = string.char(byte)
            return table.concat(out)
        else
            k = k + 1; out[k] = string.char(byte | 0x80)
        end
    end
end

function M.decode_uint(s, pos)
    if type(s) ~= "string" then
        error("varint.decode_uint: expected string, got " .. type(s))
    end
    pos = pos or 1
    local result = 0
    local shift = 0
    local len = #s
    while pos <= len do
        local b = s:byte(pos)
        pos = pos + 1
        result = result | ((b & 0x7F) << shift)
        if (b & 0x80) == 0 then
            return result, pos
        end
        shift = shift + 7
        if shift >= 64 then
            error("varint.decode_uint: value exceeds 64 bits")
        end
    end
    error("varint.decode_uint: truncated input")
end

function M.encode_sint(n)
    if type(n) ~= "number" then
        error("varint.encode_sint: expected number, got " .. type(n))
    end
    if math.type and math.type(n) ~= "integer" then
        if n ~= math.floor(n) then
            error("varint.encode_sint: non-integer value")
        end
        n = math.tointeger(n)
    end
    -- ZigZag: (n << 1) XOR (n >> 63 arithmetic). In Lua 5.4, >> on signed integers
    -- is logical, so we sign-extend manually via the conditional.
    local zz
    if n >= 0 then
        zz = n << 1
    else
        zz = ((-n) << 1) - 1
    end
    return M.encode_uint(zz)
end

function M.decode_sint(s, pos)
    local zz, next_pos = M.decode_uint(s, pos)
    local n
    if (zz & 1) == 0 then
        n = zz >> 1
    else
        n = -((zz >> 1) + 1)
    end
    return n, next_pos
end

function M.size_uint(n)
    if n == 0 then return 1 end
    local bytes = 0
    while n ~= 0 do
        bytes = bytes + 1
        n = n >> 7
    end
    return bytes
end

return M
