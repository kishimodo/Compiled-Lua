-- cache_ttl -- TTL-based expiry cache.
--
-- Each entry carries an absolute expiry timestamp. Eviction strategy is:
--   * Lazy: every get / contains / expires_at checks the entry and drops
--     it if past expiry.
--   * Active sweep: cleanup() walks all entries and drops expired ones.
--     Suitable for periodic invocation by a scheduler.
--   * Capacity overflow: when max_size is hit on insert, evict the entry
--     with the soonest expiry (an "earliest first" sweep across the map).
--     This costs O(n) per overflow event; deliberate -- the alternative
--     is maintaining a heap and paying log-N on every set in the common
--     case where the cache stays below capacity.
--
-- Public surface:
--   cache_ttl.new(opts?)               -> cache
--     opts: { default_ttl=300, max_size=10000, sweep_interval=60 }
--
-- cache methods:
--   :get(key)                          -> value | nil   (nil if expired)
--   :set(key, value, ttl?)             -- ttl seconds, falls back to default
--   :delete(key)                       -> bool
--   :touch(key, ttl?)                  -- reset expiry to now+ttl
--   :expires_at(key)                   -> timestamp | nil
--   :contains(key)                     -> bool
--   :peek(key)                         -> value | nil  (no expiry check)
--   :size()                            -- live entry count (may include expired)
--   :cleanup()                         -- force sweep; returns count dropped
--   :stats()                           -> {hits=, misses=, evictions=, expirations=}
--   :clear()
--
-- sweep_interval is informational -- this package doesn't spawn a thread.
-- The expected pattern is: cache:cleanup() called from a scheduler tick
-- every sweep_interval seconds. The :get path also opportunistically runs
-- a partial sweep if the last sweep was older than sweep_interval.

local M = {}

local os_time = os.time

local function new_stats()
    return { hits = 0, misses = 0, evictions = 0, expirations = 0, sets = 0 }
end

local Cache = {}
Cache.__index = Cache

-- Internal: remove a single key from the live set + bump expirations.
local function expire_entry(self, key)
    self._entries[key] = nil
    self._size = self._size - 1
    self._stats.expirations = self._stats.expirations + 1
end

-- Find the entry with the soonest expiry; O(n) over the map.
local function find_earliest(self)
    local soonest, soonest_at = nil, math.huge
    local no_expiry_key = nil
    for k, e in pairs(self._entries) do
        if e.expires_at == nil then
            -- Entries with no TTL act as a last-resort eviction target so
            -- max_size still functions on caches that mix TTL'd and immortal items.
            no_expiry_key = no_expiry_key or k
        elseif e.expires_at < soonest_at then
            soonest    = k
            soonest_at = e.expires_at
        end
    end
    return soonest or no_expiry_key
end

-- Opportunistic sweep -- called from :get to amortize expiry work.
local function maybe_sweep(self)
    local now = os_time()
    if (now - self._last_sweep) < self._sweep_interval then return end
    self._last_sweep = now
    -- Note: we don't walk the whole map here; we just trim a bounded slice
    -- (up to 64 entries) so :get latency stays predictable. The user can
    -- still call :cleanup() for a guaranteed full pass.
    local budget = 64
    for k, e in pairs(self._entries) do
        if budget == 0 then break end
        budget = budget - 1
        if e.expires_at and e.expires_at <= now then
            expire_entry(self, k)
        end
    end
end

function Cache:get(key)
    maybe_sweep(self)
    local e = self._entries[key]
    if e == nil then
        self._stats.misses = self._stats.misses + 1
        return nil
    end
    if e.expires_at and e.expires_at <= os_time() then
        expire_entry(self, key)
        self._stats.misses = self._stats.misses + 1
        return nil
    end
    self._stats.hits = self._stats.hits + 1
    return e.value
end

function Cache:peek(key)
    local e = self._entries[key]
    return e and e.value or nil
end

function Cache:contains(key)
    local e = self._entries[key]
    if e == nil then return false end
    if e.expires_at and e.expires_at <= os_time() then
        expire_entry(self, key)
        return false
    end
    return true
end

function Cache:set(key, value, ttl)
    self._stats.sets = self._stats.sets + 1
    local effective_ttl = ttl or self._default_ttl
    local expires_at = effective_ttl and (os_time() + effective_ttl) or nil
    local existing = self._entries[key]
    if existing ~= nil then
        existing.value      = value
        existing.expires_at = expires_at
        return
    end
    -- Capacity check on new insert.
    if self._max_size and self._size >= self._max_size then
        local victim = find_earliest(self)
        if victim then
            self._entries[victim] = nil
            self._size = self._size - 1
            self._stats.evictions = self._stats.evictions + 1
        end
    end
    self._entries[key] = { value = value, expires_at = expires_at }
    self._size = self._size + 1
end

function Cache:delete(key)
    if self._entries[key] == nil then return false end
    self._entries[key] = nil
    self._size = self._size - 1
    return true
end

function Cache:touch(key, ttl)
    local e = self._entries[key]
    if e == nil then return false end
    local effective_ttl = ttl or self._default_ttl
    e.expires_at = effective_ttl and (os_time() + effective_ttl) or nil
    return true
end

function Cache:expires_at(key)
    local e = self._entries[key]
    return e and e.expires_at or nil
end

function Cache:size() return self._size end

function Cache:cleanup()
    local now = os_time()
    self._last_sweep = now
    local dropped = 0
    for k, e in pairs(self._entries) do
        if e.expires_at and e.expires_at <= now then
            expire_entry(self, k)
            dropped = dropped + 1
        end
    end
    return dropped
end

function Cache:clear()
    self._entries    = {}
    self._size       = 0
    self._stats      = new_stats()
    self._last_sweep = os_time()
end

function Cache:stats()
    return {
        hits        = self._stats.hits,
        misses      = self._stats.misses,
        evictions   = self._stats.evictions,
        expirations = self._stats.expirations,
        sets        = self._stats.sets,
        size        = self._size,
        max_size    = self._max_size,
    }
end

-- Iterate over (key, value) of currently live (non-expired) entries.
function Cache:pairs()
    local now = os_time()
    local k = nil
    return function()
        while true do
            local v
            k, v = next(self._entries, k)
            if k == nil then return nil end
            if v.expires_at == nil or v.expires_at > now then
                return k, v.value
            end
        end
    end
end

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        _default_ttl    = opts.default_ttl or 300,
        _max_size       = opts.max_size or 10000,
        _sweep_interval = opts.sweep_interval or 60,
        _entries        = {},
        _size           = 0,
        _stats          = new_stats(),
        _last_sweep     = os_time(),
    }, Cache)
end

return M
