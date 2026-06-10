-- base16 -- RFC 4648 section 8 (Base16, a.k.a. hex).
--
-- Public surface:
--   base16.encode(bytes, upper?) -> string
--   base16.decode(s)             -> bytes
--
-- `upper` defaults to true (RFC says the canonical encoding is uppercase).
-- Decode is case-insensitive and skips whitespace.

local M = {}

local _enc_upper = {}
local _enc_lower = {}
local _dec = {}

for i = 0, 15 do
    _enc_upper[i] = string.format("%X", i)
    _enc_lower[i] = string.format("%x", i)
end
for i = 0, 9 do _dec[48 + i] = i end                 -- '0'..'9'
for i = 0, 5 do _dec[65 + i] = 10 + i end            -- 'A'..'F'
for i = 0, 5 do _dec[97 + i] = 10 + i end            -- 'a'..'f'

function M.encode(bytes, upper)
    if type(bytes) ~= "string" then
        error("base16.encode: expected string, got " .. type(bytes))
    end
    if upper == nil then upper = true end
    local tbl = upper and _enc_upper or _enc_lower
    local len = #bytes
    local out = {}
    for i = 1, len do
        local b = bytes:byte(i)
        out[2 * i - 1] = tbl[(b >> 4) & 0x0F]
        out[2 * i]     = tbl[b & 0x0F]
    end
    return table.concat(out)
end

function M.decode(s)
    if type(s) ~= "string" then
        error("base16.decode: expected string, got " .. type(s))
    end
    -- Strip whitespace.
    local clean = s:gsub("[%s]", "")
    local len = #clean
    if len % 2 ~= 0 then
        error("base16.decode: odd input length")
    end
    local out, n = {}, 0
    local i = 1
    while i <= len do
        local hi = _dec[clean:byte(i)]
        local lo = _dec[clean:byte(i + 1)]
        if hi == nil or lo == nil then
            error(string.format("base16.decode: invalid hex digit at offset %d", i))
        end
        n = n + 1; out[n] = string.char((hi << 4) | lo)
        i = i + 2
    end
    return table.concat(out)
end

return M
