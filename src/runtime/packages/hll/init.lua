-- hll -- HyperLogLog cardinality estimator (HLL / HLL++).
--
-- Public surface:
--   hll.new(precision?)        -> hll                (precision 4..18, default 14)
--   h:add(item)                -> self
--   h:count()                  -> approximate unique count
--   h:merge(other)             -> self
--   h:size()                   -> m (= 2^p, register count)
--   h:serialize()              -> string
--   h:deserialize(s)           -> self
--   hll.deserialize(s)         -> hll
--
-- Algorithm:
--   For each item, take a 64-bit hash. Use the top `p` bits as the
--   register index (m = 2^p registers). Count the number of leading zeros
--   in the remaining (64 - p) bits plus 1, store the max per register.
--   E = alpha_m * m^2 / sum(2^-M[j])
--   Small-range correction: linear counting when E <= 2.5 * m.

local M = {}

-- ===== FNV-1a 64 + a second mix for hash diffusion =====================
--
-- HLL really wants a "uniformly distributed" hash. FNV-1a is OK as a
-- starting point; we follow it with a SplitMix64 round to scramble the
-- bits so the leading-zero count is well-behaved.

local FNV_OFFSET = 0xcbf29ce484222325
local FNV_PRIME  = 0x00000100000001b3

local function fnv1a_64(s)
    local h = FNV_OFFSET
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    end
    return h
end

local function splitmix64(z)
    z = (z + 0x9e3779b97f4a7c15) & 0xFFFFFFFFFFFFFFFF
    z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9 & 0xFFFFFFFFFFFFFFFF
    z = (z ~ (z >> 27)) * 0x94d049bb133111eb & 0xFFFFFFFFFFFFFFFF
    return z ~ (z >> 31)
end

local function hash64(s)
    return splitmix64(fnv1a_64(s))
end

local function key_of(item)
    local t = type(item)
    if t == "string" then return item end
    if t == "number" then return tostring(item) end
    if t == "boolean" then return item and "t" or "f" end
    return tostring(item)
end

-- ===== Helpers =========================================================

local function leading_zeros_plus_one(x, w)
    -- Count leading zeros of an `w`-bit number `x`, then +1 (HLL "rho").
    if x == 0 then return w + 1 end
    local n = 1
    local mask = 1 << (w - 1)
    while (x & mask) == 0 do
        n = n + 1
        mask = mask >> 1
    end
    return n
end

local function alpha(m)
    if m == 16  then return 0.673 end
    if m == 32  then return 0.697 end
    if m == 64  then return 0.709 end
    return 0.7213 / (1 + 1.079 / m)
end

-- ===== HLL =============================================================

local HLL = {}
HLL.__index = HLL

function M.new(precision)
    precision = precision or 14
    assert(precision >= 4 and precision <= 18,
        "hll: precision must be in 4..18")
    local m = 1 << precision
    local regs = {}
    for i = 1, m do regs[i] = 0 end
    return setmetatable({
        _p     = precision,
        _m     = m,
        _alpha = alpha(m),
        _regs  = regs,
        _w     = 64 - precision,  -- bits available for rho
    }, HLL)
end

function HLL:size() return self._m end

function HLL:add(item)
    local h = hash64(key_of(item))
    -- Top p bits = register index; remaining = rho input.
    local idx = (h >> self._w) + 1
    local mask = (1 << self._w) - 1
    local tail = h & mask
    local rho  = leading_zeros_plus_one(tail, self._w)
    if rho > self._regs[idx] then self._regs[idx] = rho end
    return self
end

function HLL:count()
    local sum = 0.0
    local zeros = 0
    local regs = self._regs
    local m = self._m
    for i = 1, m do
        local v = regs[i]
        if v == 0 then zeros = zeros + 1 end
        sum = sum + 2.0 ^ (-v)
    end
    local E = self._alpha * m * m / sum

    -- Small-range correction (linear counting) for sparse fill.
    if E <= 2.5 * m and zeros ~= 0 then
        return math.floor(m * math.log(m / zeros) + 0.5)
    end

    -- Large-range correction for 64-bit hash isn't required (collisions
    -- in a 2^64 space are negligible for any practical n). Return raw.
    return math.floor(E + 0.5)
end

function HLL:merge(other)
    assert(other._m == self._m, "hll: cannot merge HLLs of different precision")
    for i = 1, self._m do
        if other._regs[i] > self._regs[i] then
            self._regs[i] = other._regs[i]
        end
    end
    return self
end

-- ===== Serialization ===================================================
--
-- Layout: "HLL1|p|" + raw bytes (one byte per register; rho is in 1..65).

function HLL:serialize()
    local header = string.format("HLL1|%d|", self._p)
    local parts = {}
    parts[1] = header
    local chunk = {}
    local cn = 0
    for i = 1, self._m do
        cn = cn + 1
        chunk[cn] = string.char(self._regs[i] & 0xFF)
        if (i & 0xFFF) == 0 then
            parts[#parts + 1] = table.concat(chunk)
            chunk = {}
            cn = 0
        end
    end
    if cn > 0 then parts[#parts + 1] = table.concat(chunk) end
    return table.concat(parts)
end

function M.deserialize(s)
    local p, rest = s:match("^HLL1|(%d+)|(.*)$")
    if not p then return nil, "bad hll blob" end
    p = tonumber(p)
    local h = M.new(p)
    if #rest ~= h._m then
        return nil, "hll blob length mismatch"
    end
    for i = 1, h._m do
        h._regs[i] = rest:byte(i)
    end
    return h
end

function HLL:deserialize(s)
    local other, err = M.deserialize(s)
    if not other then return nil, err end
    self._p, self._m, self._alpha = other._p, other._m, other._alpha
    self._regs, self._w           = other._regs, other._w
    return self
end

return M
