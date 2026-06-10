-- random -- CSPRNG (BCryptGenRandom) plus fast non-crypto generators.
--
-- Public surface (module-level convenience uses CSPRNG by default; call
-- random.seed(n) to switch the module-level helpers onto a deterministic
-- xoshiro256** instance):
--   random.bytes(n)               -> n bytes
--   random.int(min, max)          -> uniform integer in [min, max], unbiased
--   random.float()                -> uniform float in [0, 1)
--   random.choice(t)              -> uniformly-selected element
--   random.shuffle(t)             -> Fisher-Yates in place; returns the table
--   random.seed(n)                -> switch the convenience funcs to a deterministic PRNG
--   random.prng(name, seed?)      -> stateful RNG object; name in
--                                    "xoshiro256**", "splitmix64", "pcg32",
--                                    "mulberry32"
--
-- Legacy names retained:
--   random.secure_bytes / secure_int / secure_double
--   random.xoshiro / splitmix / pcg
--
-- RNG objects expose:
--   :uint64() -> integer
--   :uint32() -> integer (0..2^32-1)
--   :double() -> [0, 1)
--   :bytes(n) -> string of n random bytes
--   :range(min, max) -> integer in [min, max], unbiased
--   :choice(t)            -- delegates to module helper
--   :shuffle(t)           -- delegates to module helper

require "windows"
local BC = require "windows.bcrypt"

local M = {}

local MASK64 = 0xFFFFFFFFFFFFFFFF
local MASK32 = 0xFFFFFFFF

local function rotl64(x, r)
    return ((x << r) | (x >> (64 - r))) & MASK64
end

-- ===== Secure (CNG) ====================================================

function M.secure_bytes(n)
    if type(n) ~= "number" or n < 0 then error("random.secure_bytes: bad count") end
    if n == 0 then return "" end
    local buf = ffi.new("unsigned char[?]", n)
    local status = ffi.C.BCryptGenRandom(nil, buf, n, BC.USE_SYSTEM_PREFERRED_RNG)
    if status ~= 0 then
        error(string.format("random: BCryptGenRandom failed 0x%08X", status))
    end
    return ffi.string(buf, n)
end

local function uint64_from_bytes(s, i)
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(i, i + 7)
    return b1
        | (b2 << 8)  | (b3 << 16) | (b4 << 24)
        | (b5 << 32) | (b6 << 40) | (b7 << 48) | (b8 << 56)
end

-- Unsigned 64-bit modulo. Lua 5.4 integers are signed and '%' is floored, so a
-- value with the top bit set (negative when signed) needs correcting back to its
-- true unsigned residue. true_unsigned = a + 2^64 when a < 0, hence
--   umod(a, m) = (a % m + 2^64 % m) % m  for a < 0.
local function umod(a, span)
    if a >= 0 then return a % span end
    local two64 = (((1 << 32) % span) * ((1 << 32) % span)) % span
    return ((a % span) + two64) % span
end

local function unbiased_range(get_uint64, lo, hi)
    if hi < lo then error("random: range max < min") end
    local span = hi - lo + 1
    if span <= 0 then error("random: span overflow") end
    if span == 1 then return lo end
    -- Rejection-sample to avoid modulo bias, using UNSIGNED semantics throughout.
    -- Reject the lowest 't' unsigned values so the accepted window [t, 2^64) has a
    -- size that is an exact multiple of span. t = 2^64 mod span (== umod(-span)).
    local t = umod(-span, span)
    while true do
        local r = get_uint64() & MASK64
        if not math.ult(r, t) then
            return lo + umod(r, span)
        end
    end
end

function M.secure_int(min, max)
    if type(min) ~= "number" or type(max) ~= "number" then
        error("random.secure_int: min, max required")
    end
    local function gen()
        return uint64_from_bytes(M.secure_bytes(8), 1)
    end
    return unbiased_range(gen, min, max)
end

function M.secure_double()
    -- Top 53 bits give a uniform double in [0, 1) with full mantissa resolution.
    local v = uint64_from_bytes(M.secure_bytes(8), 1) >> 11
    return v / 2 ^ 53
end

-- ===== Shared helpers for stateful RNG objects =========================

local function bytes_from_uint64(get_uint64, n)
    local out, j = {}, 0
    while n > 0 do
        local v = get_uint64() & MASK64
        local take = math.min(n, 8)
        for i = 0, take - 1 do
            j = j + 1
            out[j] = string.char((v >> (i * 8)) & 0xFF)
        end
        n = n - take
    end
    return table.concat(out)
end

local function attach_common(obj, get_uint64)
    function obj:bytes(n) return bytes_from_uint64(get_uint64, n) end
    -- Only install the generic uint32 if the underlying generator doesn't have a native one.
    if rawget(getmetatable(obj) or {}, "uint32") == nil then
        function obj:uint32() return get_uint64() & MASK32 end
    end
    function obj:double()
        local v = get_uint64() >> 11
        return v / 2 ^ 53
    end
    function obj:range(lo, hi) return unbiased_range(get_uint64, lo, hi) end
    return obj
end

-- ===== splitmix64 ======================================================
-- Used standalone and to seed the bigger generators.

local Splitmix = {}
Splitmix.__index = Splitmix

function Splitmix:uint64()
    self._s = (self._s + 0x9E3779B97F4A7C15) & MASK64
    local z = self._s
    z = ((z ~ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    z = ((z ~ (z >> 27)) * 0x94D049BB133111EB) & MASK64
    return (z ~ (z >> 31)) & MASK64
end

local function splitmix_new(seed)
    if seed == nil then
        seed = uint64_from_bytes(M.secure_bytes(8), 1)
    end
    local obj = setmetatable({ _s = seed & MASK64 }, Splitmix)
    return attach_common(obj, function() return obj:uint64() end)
end

M.splitmix = splitmix_new

-- ===== xoshiro256** ====================================================

local Xoshiro = {}
Xoshiro.__index = Xoshiro

function Xoshiro:uint64()
    local s = self._s
    local result = (rotl64((s[2] * 5) & MASK64, 7) * 9) & MASK64
    local t = (s[2] << 17) & MASK64
    s[3] = (s[3] ~ s[1]) & MASK64
    s[4] = (s[4] ~ s[2]) & MASK64
    s[2] = (s[2] ~ s[3]) & MASK64
    s[1] = (s[1] ~ s[4]) & MASK64
    s[3] = (s[3] ~ t)    & MASK64
    s[4] = rotl64(s[4], 45)
    return result
end

local function xoshiro_new(seed)
    -- Use splitmix64 to expand a 64-bit seed into the 256-bit state, per the
    -- canonical xoshiro recommendation. With no seed we draw the full 256-bit
    -- state directly from CSPRNG bytes; either way we reject the all-zero state.
    local s
    if seed == nil then
        local raw = M.secure_bytes(32)
        s = {
            uint64_from_bytes(raw,  1),
            uint64_from_bytes(raw,  9),
            uint64_from_bytes(raw, 17),
            uint64_from_bytes(raw, 25),
        }
    else
        local sm = splitmix_new(seed)
        s = { sm:uint64(), sm:uint64(), sm:uint64(), sm:uint64() }
    end
    if s[1] == 0 and s[2] == 0 and s[3] == 0 and s[4] == 0 then
        s[1] = 1
    end
    local obj = setmetatable({ _s = s }, Xoshiro)
    return attach_common(obj, function() return obj:uint64() end)
end

M.xoshiro = xoshiro_new

-- ===== PCG32 ===========================================================
-- O'Neill PCG-XSH-RR (32-bit output, 64-bit state).

local Pcg = {}
Pcg.__index = Pcg

function Pcg:uint32()
    local old = self._state
    self._state = ((old * 6364136223846793005) + self._inc) & MASK64
    local xorshifted = (((old >> 18) ~ old) >> 27) & MASK32
    local rot = (old >> 59) & 31
    return ((xorshifted >> rot) | ((xorshifted << ((32 - rot) & 31)) & MASK32)) & MASK32
end

-- For PCG we still want a 64-bit primitive for :bytes/:range. Compose two u32s.
function Pcg:uint64()
    local hi = self:uint32()
    local lo = self:uint32()
    return ((hi << 32) | lo) & MASK64
end

local function pcg_new(seed)
    -- PCG initialisation per the reference: increment must be odd.
    local s, inc
    if seed == nil then
        local raw = M.secure_bytes(16)
        s   = uint64_from_bytes(raw, 1)
        inc = uint64_from_bytes(raw, 9) | 1
    else
        local sm = splitmix_new(seed)
        s = sm:uint64()
        inc = sm:uint64() | 1
    end
    local obj = setmetatable({ _state = 0, _inc = inc }, Pcg)
    -- Standard PCG seeding warmup.
    obj._state = (obj._state + s) & MASK64
    obj:uint32()
    return attach_common(obj, function() return obj:uint64() end)
end

M.pcg = pcg_new

-- ===== mulberry32 ======================================================
-- Small + fast 32-bit non-crypto PRNG.

local Mulberry = {}
Mulberry.__index = Mulberry

function Mulberry:uint32()
    self._s = (self._s + 0x6D2B79F5) & MASK32
    local z = self._s
    z = ((z ~ (z >> 15)) * (z | 1)) & MASK32
    z = (z ~ (z + (((z ~ (z >> 7)) * (z | 61)) & MASK32))) & MASK32
    return (z ~ (z >> 14)) & MASK32
end

function Mulberry:uint64()
    local hi = self:uint32()
    local lo = self:uint32()
    return ((hi << 32) | lo) & MASK64
end

local function mulberry_new(seed)
    if seed == nil then
        seed = uint64_from_bytes(M.secure_bytes(4), 1) & MASK32
    end
    local obj = setmetatable({ _s = seed & MASK32 }, Mulberry)
    return attach_common(obj, function() return obj:uint64() end)
end

M.mulberry = mulberry_new

-- ===== PRNG dispatcher =================================================

local PRNG_BY_NAME = {
    ["xoshiro256**"] = xoshiro_new,
    ["xoshiro256"]   = xoshiro_new,
    ["xoshiro"]      = xoshiro_new,
    ["splitmix64"]   = splitmix_new,
    ["splitmix"]     = splitmix_new,
    ["pcg32"]        = pcg_new,
    ["pcg"]          = pcg_new,
    ["mulberry32"]   = mulberry_new,
    ["mulberry"]     = mulberry_new,
}

function M.prng(name, seed)
    local ctor = PRNG_BY_NAME[name]
    if ctor == nil then
        error("random.prng: unknown PRNG '" .. tostring(name) .. "'")
    end
    return ctor(seed)
end

-- ===== Convenience surface (CSPRNG by default; switched by M.seed) =====

-- _conv_rng == nil means "use the CSPRNG path"; assigning a PRNG object
-- (via M.seed) flips every convenience helper to it.
local _conv_rng = nil

function M.bytes(n)
    if _conv_rng then return _conv_rng:bytes(n) end
    return M.secure_bytes(n)
end

function M.int(lo, hi)
    if _conv_rng then return _conv_rng:range(lo, hi) end
    return M.secure_int(lo, hi)
end

function M.float()
    if _conv_rng then return _conv_rng:double() end
    return M.secure_double()
end

function M.choice(t)
    local n = #t
    if n == 0 then return nil end
    return t[M.int(1, n)]
end

function M.shuffle(t)
    local n = #t
    for i = n, 2, -1 do
        local j = M.int(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function M.seed(n)
    if n == nil then
        _conv_rng = nil
        return
    end
    _conv_rng = xoshiro_new(n)
end

-- Object-side choice/shuffle (delegating to module helpers but bound to the
-- specific RNG instance).
local function add_choice_shuffle(rng)
    function rng:choice(t)
        local n = #t
        if n == 0 then return nil end
        return t[self:range(1, n)]
    end
    function rng:shuffle(t)
        local n = #t
        for i = n, 2, -1 do
            local j = self:range(1, i)
            t[i], t[j] = t[j], t[i]
        end
        return t
    end
end

-- Patch all constructors to add the extra surface.
local function wrap_ctor(orig)
    return function(...)
        local r = orig(...)
        add_choice_shuffle(r)
        return r
    end
end
M.xoshiro  = wrap_ctor(xoshiro_new)
M.splitmix = wrap_ctor(splitmix_new)
M.pcg      = wrap_ctor(pcg_new)
M.mulberry = wrap_ctor(mulberry_new)
local _prng_orig = M.prng
function M.prng(name, seed)
    local r = _prng_orig(name, seed)
    add_choice_shuffle(r)
    return r
end

return M
