-- base85 -- two variants:
--   "rfc1924" -- the IPv6 alphabet defined in RFC 1924 (default)
--   "adobe"   -- the Adobe Ascii85 dialect: '!'..'u' alphabet,
--                'z' shorthand for an all-zero 4-byte group,
--                '<~' / '~>' framing delimiters.
--
-- Public surface:
--   base85.encode(bytes, variant?) -> string
--   base85.decode(s, variant?)     -> bytes

local M = {}

-- Per RFC 1924: 0..9 A..Z a..z then the punctuation listed below, in order.
local RFC1924_ALPHABET =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~"

-- Adobe Ascii85: '!' (0x21) through 'u' (0x75) -- a 1:1 mapping.
local function _adobe_char(i)        return string.char(i + 0x21) end
local function _adobe_value(b)       return b - 0x21 end

local _rfc_enc, _rfc_dec = {}, {}
for i = 1, 85 do
    local c = RFC1924_ALPHABET:sub(i, i)
    _rfc_enc[i - 1] = c
    _rfc_dec[c:byte()] = i - 1
end

local POW85 = { 1, 85, 85 * 85, 85 * 85 * 85, 85 * 85 * 85 * 85 }

local function encode_word(out, n, v, enc_fn)
    -- Emit a 5-character base85 word for the 32-bit value v.
    local c5 = v % 85; v = (v - c5) / 85
    local c4 = v % 85; v = (v - c4) / 85
    local c3 = v % 85; v = (v - c3) / 85
    local c2 = v % 85; v = (v - c2) / 85
    local c1 = v % 85
    out[n + 1] = enc_fn(c1)
    out[n + 2] = enc_fn(c2)
    out[n + 3] = enc_fn(c3)
    out[n + 4] = enc_fn(c4)
    out[n + 5] = enc_fn(c5)
    return n + 5
end

function M.encode(bytes, variant)
    if type(bytes) ~= "string" then
        error("base85.encode: expected string, got " .. type(bytes))
    end
    variant = variant or "rfc1924"
    local enc_fn
    if variant == "rfc1924" then
        enc_fn = function(i) return _rfc_enc[i] end
    elseif variant == "adobe" then
        enc_fn = _adobe_char
    else
        error("base85.encode: unknown variant '" .. tostring(variant) .. "'")
    end

    local len = #bytes
    local out, n = {}, 0
    if variant == "adobe" then
        n = n + 1; out[n] = "<~"
    end
    local i = 1
    while i + 3 <= len do
        local b1, b2, b3, b4 = bytes:byte(i, i + 3)
        local v = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        -- Adobe 'z' shorthand for an all-zero 32-bit word.
        if variant == "adobe" and v == 0 then
            n = n + 1; out[n] = "z"
        else
            n = encode_word(out, n, v, enc_fn)
        end
        i = i + 4
    end
    local rem = len - i + 1
    if rem > 0 then
        local b1, b2, b3, b4 = 0, 0, 0, 0
        b1 = bytes:byte(i)
        if rem >= 2 then b2 = bytes:byte(i + 1) end
        if rem >= 3 then b3 = bytes:byte(i + 2) end
        if rem >= 4 then b4 = bytes:byte(i + 3) end
        local v = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        local c5 = v % 85; v = (v - c5) / 85
        local c4 = v % 85; v = (v - c4) / 85
        local c3 = v % 85; v = (v - c3) / 85
        local c2 = v % 85; v = (v - c2) / 85
        local c1 = v % 85
        -- Emit only rem+1 characters of the partial word.
        local chars = { c1, c2, c3, c4, c5 }
        for k = 1, rem + 1 do
            n = n + 1; out[n] = enc_fn(chars[k])
        end
    end
    if variant == "adobe" then
        n = n + 1; out[n] = "~>"
    end
    return table.concat(out)
end

function M.decode(s, variant)
    if type(s) ~= "string" then
        error("base85.decode: expected string, got " .. type(s))
    end
    variant = variant or "rfc1924"
    local dec_fn
    if variant == "rfc1924" then
        dec_fn = function(b) return _rfc_dec[b] end
    elseif variant == "adobe" then
        dec_fn = function(b)
            if b < 0x21 or b > 0x75 then return nil end
            return _adobe_value(b)
        end
    else
        error("base85.decode: unknown variant '" .. tostring(variant) .. "'")
    end

    -- Trim Adobe framing if present.
    if variant == "adobe" then
        local a, b = s:find("^%s*<~")
        if a then s = s:sub(b + 1) end
        local c = s:find("~>")
        if c then s = s:sub(1, c - 1) end
    end

    local len = #s
    local out, n = {}, 0
    local group, gn = { 0, 0, 0, 0, 0 }, 0
    local i = 1
    while i <= len do
        local b = s:byte(i)
        i = i + 1
        if b == 32 or b == 9 or b == 10 or b == 13 then
            -- skip whitespace
        elseif variant == "adobe" and b == 122 then  -- 'z' shorthand
            if gn ~= 0 then
                error("base85.decode: 'z' inside partial word")
            end
            n = n + 1; out[n] = "\0\0\0\0"
        else
            local v = dec_fn(b)
            if v == nil then
                error(string.format("base85.decode: invalid character 0x%02X at offset %d", b, i - 1))
            end
            gn = gn + 1
            group[gn] = v
            if gn == 5 then
                local val = ((group[1] * 85 + group[2]) * 85 + group[3]) * 85 * 85
                           + group[4] * 85 + group[5]
                n = n + 1; out[n] = string.char(
                    (val >> 24) & 0xFF,
                    (val >> 16) & 0xFF,
                    (val >> 8) & 0xFF,
                    val & 0xFF)
                gn = 0
            end
        end
    end
    if gn > 0 then
        if gn == 1 then
            error("base85.decode: trailing single character is invalid")
        end
        -- Pad partial group with the maximum digit 'u'/84.
        for k = gn + 1, 5 do group[k] = 84 end
        local val = ((group[1] * 85 + group[2]) * 85 + group[3]) * 85 * 85
                   + group[4] * 85 + group[5]
        local bytes_out = string.char(
            (val >> 24) & 0xFF,
            (val >> 16) & 0xFF,
            (val >> 8) & 0xFF,
            val & 0xFF)
        n = n + 1; out[n] = bytes_out:sub(1, gn - 1)
    end
    return table.concat(out)
end

return M
