-- hmac -- HMAC (RFC 2104) layered over the hash package.
--
-- Public surface:
--   hmac(algo, key, msg)       -> raw MAC bytes (callable module shorthand)
--   hmac.new(algo, key)        -> ctx with :update/:digest/:hexdigest/:reset
--                                 (legacy :final/:final_hex aliases retained)
--   hmac.<algo>(key, msg)      -> raw MAC bytes (md5, sha1, sha256/384/512,
--                                                sha3_256/384/512, blake3)
--   hmac.<algo>_hex(key, msg)  -> lowercase hex string
--   hmac.<algo>_b64(key, msg)  -> base64 (standard alphabet, no padding)
--   hmac.equals(a, b)          -> bool, constant time

local hash = require "hash"

local M = {}

local IPAD = 0x36
local OPAD = 0x5C

-- Compute the "block-sized key" K' per RFC 2104: hash the key if too long,
-- right-pad with zeros if shorter than block_size.
local function normalize_key(algo, key)
    local bs = hash.block_size(algo)
    if not bs then
        error("hmac: unsupported algorithm '" .. tostring(algo) .. "'")
    end
    if #key > bs then
        key = hash.new(algo):update(key):final()
    end
    if #key < bs then
        key = key .. string.rep("\0", bs - #key)
    end
    return key, bs
end

local function xor_pad(k, byte)
    local out, n = {}, 0
    for i = 1, #k do
        n = n + 1
        out[n] = string.char(k:byte(i) ~ byte)
    end
    return table.concat(out)
end

local Hmac = {}
Hmac.__index = Hmac

function Hmac:update(s)
    self._inner:update(s)
    return self
end

function Hmac:final()
    if self._done then return self._mac end
    local inner_digest = self._inner:final()
    local outer = hash.new(self._algo)
    outer:update(self._k_opad)
    outer:update(inner_digest)
    self._mac  = outer:final()
    self._done = true
    return self._mac
end

function Hmac:final_hex() return hash.to_hex(self:final()) end

Hmac.digest    = Hmac.final
Hmac.hexdigest = Hmac.final_hex

function Hmac:reset()
    self._inner = hash.new(self._algo)
    self._inner:update(self._k_ipad)
    self._done = false
    self._mac  = nil
    return self
end

function M.new(algo, key)
    if type(key) ~= "string" then error("hmac.new: key must be a string") end
    local k, _ = normalize_key(algo, key)
    local obj = setmetatable({
        _algo    = algo,
        _k_ipad  = xor_pad(k, IPAD),
        _k_opad  = xor_pad(k, OPAD),
    }, Hmac)
    obj:reset()
    return obj
end

-- Base64 (standard alphabet) -- no padding so the value round-trips through
-- HTTP headers cleanly. We don't pull in a real base64 package here because
-- the MAC sizes are all small (<= 64 bytes).
local _B64A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function to_b64(bytes)
    local out, n = {}, 0
    local len = #bytes
    local i = 1
    while i + 2 <= len do
        local b1, b2, b3 = bytes:byte(i, i + 2)
        local v = b1 * 65536 + b2 * 256 + b3
        local a, b, c, d = ((v >> 18) & 0x3F) + 1, ((v >> 12) & 0x3F) + 1,
                           ((v >>  6) & 0x3F) + 1, ( v        & 0x3F) + 1
        n = n + 1; out[n] = _B64A:sub(a, a)
        n = n + 1; out[n] = _B64A:sub(b, b)
        n = n + 1; out[n] = _B64A:sub(c, c)
        n = n + 1; out[n] = _B64A:sub(d, d)
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local b1 = bytes:byte(i)
        local v = b1 * 65536
        n = n + 1; out[n] = _B64A:sub(((v >> 18) & 0x3F) + 1, ((v >> 18) & 0x3F) + 1)
        n = n + 1; out[n] = _B64A:sub(((v >> 12) & 0x3F) + 1, ((v >> 12) & 0x3F) + 1)
        n = n + 1; out[n] = "=="
    elseif rem == 2 then
        local b1, b2 = bytes:byte(i, i + 1)
        local v = b1 * 65536 + b2 * 256
        n = n + 1; out[n] = _B64A:sub(((v >> 18) & 0x3F) + 1, ((v >> 18) & 0x3F) + 1)
        n = n + 1; out[n] = _B64A:sub(((v >> 12) & 0x3F) + 1, ((v >> 12) & 0x3F) + 1)
        n = n + 1; out[n] = _B64A:sub(((v >> 6) & 0x3F) + 1, ((v >> 6) & 0x3F) + 1)
        n = n + 1; out[n] = "="
    end
    return table.concat(out)
end

-- Constant-time string compare, exposed for completeness (the secret package
-- has the canonical implementation).
function M.equals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local la, lb = #a, #b
    local diff = la ~ lb
    local n = math.min(la, lb)
    for i = 1, n do diff = diff | (a:byte(i) ~ b:byte(i)) end
    return diff == 0
end

-- One-shots for each algorithm hash exposes a block size for.
local SUPPORTED = {
    "md5", "sha1",
    "sha256", "sha384", "sha512",
    "sha3_256", "sha3_384", "sha3_512",
    "blake3",
}
for _, algo in ipairs(SUPPORTED) do
    M[algo]           = function(key, msg) return M.new(algo, key):update(msg):final() end
    M[algo .. "_hex"] = function(key, msg) return hash.to_hex(M[algo](key, msg)) end
    M[algo .. "_b64"] = function(key, msg) return to_b64(M[algo](key, msg)) end
end

-- Callable module shorthand: hmac("sha256", key, msg) -> raw bytes.
return setmetatable(M, { __call = function(_, algo, key, msg)
    return M.new(algo, key):update(msg):final()
end })
