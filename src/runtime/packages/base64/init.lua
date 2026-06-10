-- base64 -- RFC 4648 section 4 (standard) + section 5 (URL-safe).
--
-- Public surface:
--   base64.encode(bytes, opts?) -> string
--   base64.decode(s, opts?)     -> bytes
--
-- opts:
--   url         -- true to use URL-safe alphabet ('-_' instead of '+/')
--   no_padding  -- true to omit '=' padding on encode (allowed on decode regardless)

local M = {}

local STD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

-- Precompute encode tables and decode lookups.
local _enc_std = {}
local _enc_url = {}
local _dec_std = {}
local _dec_url = {}

for i = 1, 64 do
    local c_std = STD_ALPHABET:sub(i, i)
    local c_url = URL_ALPHABET:sub(i, i)
    _enc_std[i - 1] = c_std
    _enc_url[i - 1] = c_url
    _dec_std[c_std:byte()] = i - 1
    _dec_url[c_url:byte()] = i - 1
end

-- Merge both alphabets into a permissive decode table -- accept either '+/'
-- or '-_' so callers don't have to know the source variant.
local _dec_any = {}
for k, v in pairs(_dec_std) do _dec_any[k] = v end
for k, v in pairs(_dec_url) do _dec_any[k] = v end

local function pick_encode_table(opts)
    if opts and opts.url then return _enc_url end
    return _enc_std
end

function M.encode(bytes, opts)
    if type(bytes) ~= "string" then
        error("base64.encode: expected string, got " .. type(bytes))
    end
    local enc = pick_encode_table(opts)
    local no_pad = opts and opts.no_padding
    local len = #bytes
    local out, n = {}, 0
    local i = 1
    -- Process full 3-byte groups.
    while i + 2 <= len do
        local b1, b2, b3 = bytes:byte(i, i + 2)
        local v = b1 * 65536 + b2 * 256 + b3
        n = n + 1; out[n] = enc[(v >> 18) & 0x3F]
        n = n + 1; out[n] = enc[(v >> 12) & 0x3F]
        n = n + 1; out[n] = enc[(v >> 6) & 0x3F]
        n = n + 1; out[n] = enc[v & 0x3F]
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local b1 = bytes:byte(i)
        local v = b1 * 65536
        n = n + 1; out[n] = enc[(v >> 18) & 0x3F]
        n = n + 1; out[n] = enc[(v >> 12) & 0x3F]
        if not no_pad then
            n = n + 1; out[n] = "="
            n = n + 1; out[n] = "="
        end
    elseif rem == 2 then
        local b1, b2 = bytes:byte(i, i + 1)
        local v = b1 * 65536 + b2 * 256
        n = n + 1; out[n] = enc[(v >> 18) & 0x3F]
        n = n + 1; out[n] = enc[(v >> 12) & 0x3F]
        n = n + 1; out[n] = enc[(v >> 6) & 0x3F]
        if not no_pad then
            n = n + 1; out[n] = "="
        end
    end
    return table.concat(out)
end

function M.decode(s, opts)
    if type(s) ~= "string" then
        error("base64.decode: expected string, got " .. type(s))
    end
    -- Pick decode table based on opts.url; default accepts either alphabet.
    local dec
    if opts and opts.url then
        dec = _dec_url
    elseif opts and opts.strict then
        dec = _dec_std
    else
        dec = _dec_any
    end
    local len = #s
    local out, n = {}, 0
    local accum, bits = 0, 0
    local i = 1
    while i <= len do
        local b = s:byte(i)
        i = i + 1
        if b == 61 then  -- '='
            break
        end
        -- Skip whitespace silently to tolerate wrapped lines.
        if b == 32 or b == 9 or b == 10 or b == 13 then
            -- noop
        else
            local v = dec[b]
            if v == nil then
                error(string.format("base64.decode: invalid character 0x%02X at offset %d", b, i - 1))
            end
            accum = (accum << 6) | v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                n = n + 1; out[n] = string.char((accum >> bits) & 0xFF)
                accum = accum & ((1 << bits) - 1)
            end
        end
    end
    -- Any leftover bits must be zero -- non-zero residue means malformed input.
    if bits >= 8 then
        error("base64.decode: dangling bits in trailer")
    end
    if accum ~= 0 and bits > 0 then
        -- Silently tolerate -- many encoders pad inputs sloppily, but flag obviously
        -- impossible residues. RFC 4648 strictly says these MUST be zero.
        if opts and opts.strict then
            error("base64.decode: non-zero padding bits")
        end
    end
    return table.concat(out)
end

return M
