-- base32 -- RFC 4648 section 6 (standard) + section 7 (base32hex).
--
-- Public surface:
--   base32.encode(bytes, opts?) -> string
--   base32.decode(s, opts?)     -> bytes
--
-- opts:
--   hex         -- true to use the base32hex alphabet ('0-9A-V')
--   no_padding  -- true to omit '=' padding on encode

local M = {}

local STD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local HEX_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUV"

local _enc_std, _dec_std = {}, {}
local _enc_hex, _dec_hex = {}, {}

for i = 1, 32 do
    local c_std = STD_ALPHABET:sub(i, i)
    local c_hex = HEX_ALPHABET:sub(i, i)
    _enc_std[i - 1] = c_std
    _enc_hex[i - 1] = c_hex
    -- Case-insensitive decode.
    _dec_std[c_std:byte()] = i - 1
    _dec_std[c_std:lower():byte()] = i - 1
    _dec_hex[c_hex:byte()] = i - 1
    _dec_hex[c_hex:lower():byte()] = i - 1
end

-- Output padding length for a residue of `r` bytes after the last full 5-byte group.
local PAD_TABLE = { [0] = 0, [1] = 6, [2] = 4, [3] = 3, [4] = 1 }

function M.encode(bytes, opts)
    if type(bytes) ~= "string" then
        error("base32.encode: expected string, got " .. type(bytes))
    end
    local enc = (opts and opts.hex) and _enc_hex or _enc_std
    local no_pad = opts and opts.no_padding
    local len = #bytes
    local out, n = {}, 0
    local i = 1
    -- Process complete 5-byte groups -> 8 output chars.
    while i + 4 <= len do
        local b1, b2, b3, b4, b5 = bytes:byte(i, i + 4)
        n = n + 1; out[n] = enc[(b1 >> 3) & 0x1F]
        n = n + 1; out[n] = enc[((b1 << 2) | (b2 >> 6)) & 0x1F]
        n = n + 1; out[n] = enc[(b2 >> 1) & 0x1F]
        n = n + 1; out[n] = enc[((b2 << 4) | (b3 >> 4)) & 0x1F]
        n = n + 1; out[n] = enc[((b3 << 1) | (b4 >> 7)) & 0x1F]
        n = n + 1; out[n] = enc[(b4 >> 2) & 0x1F]
        n = n + 1; out[n] = enc[((b4 << 3) | (b5 >> 5)) & 0x1F]
        n = n + 1; out[n] = enc[b5 & 0x1F]
        i = i + 5
    end
    local rem = len - i + 1
    if rem > 0 then
        local b1, b2, b3, b4 = 0, 0, 0, 0
        if rem >= 1 then b1 = bytes:byte(i) end
        if rem >= 2 then b2 = bytes:byte(i + 1) end
        if rem >= 3 then b3 = bytes:byte(i + 2) end
        if rem >= 4 then b4 = bytes:byte(i + 3) end
        n = n + 1; out[n] = enc[(b1 >> 3) & 0x1F]
        n = n + 1; out[n] = enc[((b1 << 2) | (b2 >> 6)) & 0x1F]
        if rem >= 2 then
            n = n + 1; out[n] = enc[(b2 >> 1) & 0x1F]
            n = n + 1; out[n] = enc[((b2 << 4) | (b3 >> 4)) & 0x1F]
        end
        if rem >= 3 then
            n = n + 1; out[n] = enc[((b3 << 1) | (b4 >> 7)) & 0x1F]
        end
        if rem >= 4 then
            n = n + 1; out[n] = enc[(b4 >> 2) & 0x1F]
            n = n + 1; out[n] = enc[((b4 << 3) | 0) & 0x1F]
        end
        if not no_pad then
            for _ = 1, PAD_TABLE[rem] do
                n = n + 1; out[n] = "="
            end
        end
    end
    return table.concat(out)
end

function M.decode(s, opts)
    if type(s) ~= "string" then
        error("base32.decode: expected string, got " .. type(s))
    end
    local dec = (opts and opts.hex) and _dec_hex or _dec_std
    local len = #s
    local out, n = {}, 0
    local accum, bits = 0, 0
    local i = 1
    while i <= len do
        local b = s:byte(i)
        i = i + 1
        if b == 61 then  -- '=' padding -- stop processing
            break
        end
        if b == 32 or b == 9 or b == 10 or b == 13 then
            -- skip whitespace
        else
            local v = dec[b]
            if v == nil then
                error(string.format("base32.decode: invalid character 0x%02X at offset %d", b, i - 1))
            end
            accum = (accum << 5) | v
            bits = bits + 5
            if bits >= 8 then
                bits = bits - 8
                n = n + 1; out[n] = string.char((accum >> bits) & 0xFF)
                accum = accum & ((1 << bits) - 1)
            end
        end
    end
    return table.concat(out)
end

return M
