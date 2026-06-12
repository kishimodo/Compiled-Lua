-- bloom -- Bloom filter, counting Bloom filter, cuckoo filter.
--
-- Public surface:
--   bloom.bloom(opts?)            -> Bloom filter
--   bloom.counting_bloom(opts?)   -> Counting Bloom filter
--   bloom.cuckoo(opts?)           -> Cuckoo filter
--
-- opts (bloom/counting): { expected_items = 1000, false_positive_rate = 0.01 }
-- opts (cuckoo):         { capacity = 1024, bucket_size = 4, fp_bits = 8,
--                          max_kicks = 500 }

local M = {}

-- ===== Hashing =========================================================
--
-- FNV-1a 64-bit (we keep only the low 53 bits to stay safe in Lua doubles
-- on hosts without integer division -- here we run on Lua 5.4 so we use
-- proper integer ops). Two independent hashes derived via:
--   h_i(x) = (h1 + i * h2) mod m   (Kirsch-Mitzenmacher double hashing)

local FNV_OFFSET = 0xcbf29ce484222325
local FNV_PRIME  = 0x00000100000001b3

local function fnv1a_64(s, seed)
    local h = (FNV_OFFSET ~ (seed or 0)) & 0xFFFFFFFFFFFFFFFF
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    end
    return h
end

local function two_hashes(s)
    local h = fnv1a_64(s, 0)
    local h1 = (h >> 32) & 0xFFFFFFFF
    local h2 = h & 0xFFFFFFFF
    if h2 == 0 then h2 = 1 end
    return h1, h2
end

local function tostring_key(x)
    local t = type(x)
    if t == "string" then return x end
    if t == "number" then return tostring(x) end
    if t == "boolean" then return x and "t" or "f" end
    return tostring(x)
end

-- ===== Optimal sizing ==================================================

local LN2  = math.log(2)
local LN2S = LN2 * LN2

local function compute_size(n, p)
    n = n or 1000
    p = p or 0.01
    local m = math.ceil(-(n * math.log(p)) / LN2S)
    local k = math.max(1, math.floor((m / n) * LN2 + 0.5))
    return m, k
end

-- ===== Bit array helpers (32-bit words) ================================

local function bit_new(nbits)
    local words = math.ceil(nbits / 32)
    local t = {}
    for i = 1, words do t[i] = 0 end
    return t, words
end

local function bit_set(bits, idx)
    local w = (idx >> 5) + 1
    local b = idx & 31
    bits[w] = bits[w] | (1 << b)
end

local function bit_get(bits, idx)
    local w = (idx >> 5) + 1
    local b = idx & 31
    return (bits[w] >> b) & 1 == 1
end

local function bit_popcount32(x)
    x = x - ((x >> 1) & 0x55555555)
    x = (x & 0x33333333) + ((x >> 2) & 0x33333333)
    x = (x + (x >> 4)) & 0x0f0f0f0f
    return ((x * 0x01010101) & 0xFFFFFFFF) >> 24
end

-- ===== Classic Bloom filter ============================================

local Bloom = {}
Bloom.__index = Bloom

function M.bloom(opts)
    opts = opts or {}
    local n = opts.expected_items or 1000
    local p = opts.false_positive_rate or 0.01
    local m, k = compute_size(n, p)
    local bits, words = bit_new(m)
    return setmetatable({
        _m = m, _k = k, _n = 0, _bits = bits, _words = words,
        _expected = n, _fp = p,
    }, Bloom)
end

function Bloom:_positions(item)
    local key = tostring_key(item)
    local h1, h2 = two_hashes(key)
    local out = {}
    for i = 0, self._k - 1 do
        out[i + 1] = ((h1 + i * h2) % self._m)
    end
    return out
end

function Bloom:add(item)
    local pos = self:_positions(item)
    local new_bits = false
    for i = 1, self._k do
        local p = pos[i]
        if not bit_get(self._bits, p) then
            bit_set(self._bits, p)
            new_bits = true
        end
    end
    if new_bits then self._n = self._n + 1 end
    return self
end

function Bloom:contains(item)
    local pos = self:_positions(item)
    for i = 1, self._k do
        if not bit_get(self._bits, pos[i]) then return false end
    end
    return true
end

function Bloom:size() return self._n end

function Bloom:bit_count()
    local c = 0
    for i = 1, self._words do c = c + bit_popcount32(self._bits[i]) end
    return c
end

function Bloom:false_positive_rate()
    -- Approximate current FPR given fill level: (1 - e^(-k*n/m))^k.
    local n_used = self._n
    if n_used == 0 then return 0 end
    return (1 - math.exp(-self._k * n_used / self._m)) ^ self._k
end

function Bloom:to_string()
    -- Header: "BF1|m|k|n|words|" + raw 4-byte LE words.
    local hdr = string.format("BF1|%d|%d|%d|%d|", self._m, self._k, self._n, self._words)
    local parts = { hdr }
    for i = 1, self._words do
        local w = self._bits[i]
        parts[#parts + 1] = string.char(
            w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF)
    end
    return table.concat(parts)
end

function M.bloom_from_string(s)
    local m, k, n, words, rest = s:match("^BF1|(%d+)|(%d+)|(%d+)|(%d+)|(.*)$")
    if not m then return nil, "bad bloom blob" end
    m, k, n, words = tonumber(m), tonumber(k), tonumber(n), tonumber(words)
    local bits = {}
    for i = 1, words do
        local off = (i - 1) * 4 + 1
        local b1, b2, b3, b4 = rest:byte(off, off + 3)
        bits[i] = b1 + (b2 << 8) + (b3 << 16) + (b4 << 24)
    end
    return setmetatable({
        _m = m, _k = k, _n = n, _bits = bits, _words = words,
    }, Bloom)
end

function Bloom:from_string(s)
    local other, err = M.bloom_from_string(s)
    if not other then return nil, err end
    self._m, self._k, self._n  = other._m, other._k, other._n
    self._bits, self._words    = other._bits, other._words
    return self
end

-- ===== Counting Bloom filter (8-bit counters) ==========================

local CBloom = {}
CBloom.__index = CBloom

function M.counting_bloom(opts)
    opts = opts or {}
    local n = opts.expected_items or 1000
    local p = opts.false_positive_rate or 0.01
    local m, k = compute_size(n, p)
    local counters = {}
    for i = 1, m do counters[i] = 0 end
    return setmetatable({
        _m = m, _k = k, _n = 0, _c = counters, _max = 255,
    }, CBloom)
end

function CBloom:_positions(item)
    local key = tostring_key(item)
    local h1, h2 = two_hashes(key)
    local out = {}
    for i = 0, self._k - 1 do
        out[i + 1] = ((h1 + i * h2) % self._m) + 1
    end
    return out
end

function CBloom:add(item)
    local pos = self:_positions(item)
    for i = 1, self._k do
        local p = pos[i]
        if self._c[p] < self._max then
            self._c[p] = self._c[p] + 1
        end
    end
    self._n = self._n + 1
    return self
end

function CBloom:remove(item)
    if not self:contains(item) then return false end
    local pos = self:_positions(item)
    for i = 1, self._k do
        local p = pos[i]
        if self._c[p] > 0 and self._c[p] < self._max then
            self._c[p] = self._c[p] - 1
        end
    end
    self._n = math.max(0, self._n - 1)
    return true
end

function CBloom:contains(item)
    local pos = self:_positions(item)
    for i = 1, self._k do
        if self._c[pos[i]] == 0 then return false end
    end
    return true
end

function CBloom:count(item)
    -- Lower-bound estimate: minimum of the k counter values.
    local pos = self:_positions(item)
    local minv = self._max
    for i = 1, self._k do
        local c = self._c[pos[i]]
        if c < minv then minv = c end
    end
    return minv
end

function CBloom:size() return self._n end

-- ===== Cuckoo filter ===================================================

local Cuckoo = {}
Cuckoo.__index = Cuckoo

local function next_pow2(n)
    local p = 1
    while p < n do p = p * 2 end
    return p
end

function M.cuckoo(opts)
    opts = opts or {}
    local capacity    = next_pow2(opts.capacity or 1024)
    local bucket_size = opts.bucket_size or 4
    local fp_bits     = opts.fp_bits or 8
    local max_kicks   = opts.max_kicks or 500
    local fp_mask     = (1 << fp_bits) - 1

    local buckets = {}
    for i = 1, capacity do
        local row = {}
        for j = 1, bucket_size do row[j] = 0 end  -- 0 = empty
        buckets[i] = row
    end

    -- Deterministic RNG for kick-out (caller-stable behaviour).
    local rng_state = 0x12345678
    local function rng()
        rng_state = (rng_state * 1103515245 + 12345) & 0x7FFFFFFF
        return rng_state
    end

    return setmetatable({
        _cap = capacity, _bs = bucket_size, _fp = fp_bits,
        _mask = fp_mask, _max_kicks = max_kicks,
        _buckets = buckets, _n = 0,
        _rng = rng,
    }, Cuckoo)
end

local function fp_of(h, mask)
    local f = h & mask
    if f == 0 then f = 1 end  -- 0 reserved for empty
    return f
end

local function alt_index(i, fp, cap)
    -- alt = i XOR hash(fp), all mod cap (cap is a power of 2).
    local h = fnv1a_64(string.char(fp & 0xFF, (fp >> 8) & 0xFF), 0)
    return ((i - 1) ~ (h & (cap - 1))) + 1
end

function Cuckoo:_indexes(item)
    local key = tostring_key(item)
    local h = fnv1a_64(key, 0)
    local fp = fp_of(h, self._mask)
    local i1 = ((h >> self._fp) % self._cap) + 1
    local i2 = alt_index(i1, fp, self._cap)
    return i1, i2, fp
end

local function bucket_insert(bucket, fp)
    for j = 1, #bucket do
        if bucket[j] == 0 then bucket[j] = fp; return true end
    end
    return false
end

local function bucket_contains(bucket, fp)
    for j = 1, #bucket do
        if bucket[j] == fp then return true end
    end
    return false
end

local function bucket_remove(bucket, fp)
    for j = 1, #bucket do
        if bucket[j] == fp then bucket[j] = 0; return true end
    end
    return false
end

function Cuckoo:add(item)
    local i1, i2, fp = self:_indexes(item)
    if bucket_insert(self._buckets[i1], fp) then
        self._n = self._n + 1
        return true
    end
    if bucket_insert(self._buckets[i2], fp) then
        self._n = self._n + 1
        return true
    end
    -- Both candidates full -- kick out.
    local i = (self._rng() % 2 == 0) and i1 or i2
    for _ = 1, self._max_kicks do
        local slot = (self._rng() % self._bs) + 1
        local bucket = self._buckets[i]
        local victim = bucket[slot]
        bucket[slot] = fp
        fp = victim
        i = alt_index(i, fp, self._cap)
        if bucket_insert(self._buckets[i], fp) then
            self._n = self._n + 1
            return true
        end
    end
    return false  -- filter is too full
end

function Cuckoo:contains(item)
    local i1, i2, fp = self:_indexes(item)
    return bucket_contains(self._buckets[i1], fp)
        or bucket_contains(self._buckets[i2], fp)
end

function Cuckoo:remove(item)
    local i1, i2, fp = self:_indexes(item)
    if bucket_remove(self._buckets[i1], fp)
       or bucket_remove(self._buckets[i2], fp) then
        self._n = math.max(0, self._n - 1)
        return true
    end
    return false
end

function Cuckoo:size() return self._n end

function Cuckoo:capacity() return self._cap * self._bs end

return M
