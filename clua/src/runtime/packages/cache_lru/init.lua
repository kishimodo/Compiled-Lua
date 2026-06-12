-- cache_lru -- in-memory LRU + LFU caches.
--
-- LRU is the classical doubly-linked list + hash table layout. The list
-- is intrusive: the cache nodes themselves carry prev/next pointers so
-- the head/tail rewiring is O(1) on get and set. Eviction pops from the
-- tail. Optional per-entry TTL is checked lazily on get -- expired entries
-- are removed and counted as misses.
--
-- LFU uses the O(1) "min-frequency bucket" algorithm: each entry knows
-- its access count, and entries with the same count live in a per-count
-- linked list. We track the minimum frequency seen across the live set
-- and evict from the head of that bucket. This avoids the log-N cost a
-- straight min-heap would impose on every get.
--
-- Public surface:
--   cache_lru.lru(capacity)              -> cache
--   cache_lru.lfu(capacity)              -> cache
--   cache_lru.lru_with_ttl(capacity, default_ttl)
--
-- cache methods:
--   :get(key)                            -> value | nil
--   :set(key, value, ttl?)
--   :delete(key)                         -> bool
--   :size()
--   :clear()
--   :stats()                             -> {hits=, misses=, evictions=}
--   :contains(key)                       -> bool   (no LRU touch)
--   :peek(key)                           -> value | nil  (no LRU touch)
--
-- Thread safety: NOT thread-safe. Wrap with the mutex package if shared.

local M = {}

-- Pull os.time once to avoid the Lua-side global lookup on every get.
local os_time = os.time

-- ===== Generic stats =====================================================

local function new_stats()
    return { hits = 0, misses = 0, evictions = 0, sets = 0 }
end

-- ===== LRU ==============================================================

local LRU = {}
LRU.__index = LRU

-- Internal: detach node from the list (it must be linked).
local function lru_unlink(self, node)
    local p, n = node.prev, node.next
    if p then p.next = n else self._head = n end
    if n then n.prev = p else self._tail = p end
    node.prev, node.next = nil, nil
end

-- Internal: link node at head (most-recently-used end).
local function lru_link_head(self, node)
    node.prev = nil
    node.next = self._head
    if self._head then self._head.prev = node end
    self._head = node
    if self._tail == nil then self._tail = node end
end

-- Internal: pop the tail and return the node (or nil if empty).
local function lru_pop_tail(self)
    local t = self._tail
    if t == nil then return nil end
    lru_unlink(self, t)
    return t
end

function LRU:get(key)
    local node = self._map[key]
    if node == nil then
        self._stats.misses = self._stats.misses + 1
        return nil
    end
    -- Lazy TTL check.
    if node.expires_at and node.expires_at <= os_time() then
        lru_unlink(self, node)
        self._map[key] = nil
        self._size = self._size - 1
        self._stats.misses = self._stats.misses + 1
        return nil
    end
    -- Promote to head.
    if node ~= self._head then
        lru_unlink(self, node)
        lru_link_head(self, node)
    end
    self._stats.hits = self._stats.hits + 1
    return node.value
end

function LRU:peek(key)
    local node = self._map[key]
    if node == nil then return nil end
    if node.expires_at and node.expires_at <= os_time() then return nil end
    return node.value
end

function LRU:contains(key)
    return self:peek(key) ~= nil
end

function LRU:set(key, value, ttl)
    self._stats.sets = self._stats.sets + 1
    local effective_ttl = ttl or self._default_ttl
    local expires_at = effective_ttl and (os_time() + effective_ttl) or nil
    local node = self._map[key]
    if node ~= nil then
        node.value = value
        node.expires_at = expires_at
        if node ~= self._head then
            lru_unlink(self, node)
            lru_link_head(self, node)
        end
        return
    end
    -- Make room if at capacity.
    if self._size >= self._capacity then
        local victim = lru_pop_tail(self)
        if victim then
            self._map[victim.key] = nil
            self._size = self._size - 1
            self._stats.evictions = self._stats.evictions + 1
        end
    end
    node = { key = key, value = value, expires_at = expires_at }
    self._map[key] = node
    lru_link_head(self, node)
    self._size = self._size + 1
end

function LRU:delete(key)
    local node = self._map[key]
    if node == nil then return false end
    lru_unlink(self, node)
    self._map[key] = nil
    self._size = self._size - 1
    return true
end

function LRU:size()  return self._size end

function LRU:clear()
    self._map  = {}
    self._head = nil
    self._tail = nil
    self._size = 0
    self._stats = new_stats()
end

function LRU:stats()
    -- Return a shallow copy so callers can't mutate our counters.
    return {
        hits      = self._stats.hits,
        misses    = self._stats.misses,
        evictions = self._stats.evictions,
        sets      = self._stats.sets,
        size      = self._size,
        capacity  = self._capacity,
    }
end

function M.lru(capacity)
    assert(type(capacity) == "number" and capacity > 0, "cache_lru.lru: capacity must be > 0")
    return setmetatable({
        _capacity    = capacity,
        _map         = {},
        _head        = nil,
        _tail        = nil,
        _size        = 0,
        _stats       = new_stats(),
        _default_ttl = nil,
    }, LRU)
end

function M.lru_with_ttl(capacity, default_ttl)
    local c = M.lru(capacity)
    c._default_ttl = default_ttl
    return c
end

-- ===== LFU (O(1) buckets) ===============================================
--
-- Data model:
--   _entries[key]      = { value, freq, prev, next }
--   _buckets[freq]     = { head, tail }   (doubly-linked list of entries)
--   _min_freq          = lowest freq with a non-empty bucket
--
-- get bumps the entry's freq, moves it from bucket[freq] -> bucket[freq+1].
-- set on a new key inserts with freq=1, may evict head of bucket[_min_freq].

local LFU = {}
LFU.__index = LFU

local function lfu_bucket(self, freq)
    local b = self._buckets[freq]
    if b == nil then
        b = { head = nil, tail = nil, count = 0 }
        self._buckets[freq] = b
    end
    return b
end

local function lfu_unlink_from(b, node)
    local p, n = node.prev, node.next
    if p then p.next = n else b.head = n end
    if n then n.prev = p else b.tail = p end
    node.prev, node.next = nil, nil
    b.count = b.count - 1
end

local function lfu_append_to(b, node)
    node.prev = b.tail
    node.next = nil
    if b.tail then b.tail.next = node else b.head = node end
    b.tail = node
    b.count = b.count + 1
end

local function lfu_promote(self, node)
    local old_b = self._buckets[node.freq]
    lfu_unlink_from(old_b, node)
    if old_b.count == 0 and node.freq == self._min_freq then
        self._min_freq = self._min_freq + 1
    end
    node.freq = node.freq + 1
    lfu_append_to(lfu_bucket(self, node.freq), node)
end

function LFU:get(key)
    local node = self._map[key]
    if node == nil then
        self._stats.misses = self._stats.misses + 1
        return nil
    end
    if node.expires_at and node.expires_at <= os_time() then
        -- Pull it out completely.
        local b = self._buckets[node.freq]
        lfu_unlink_from(b, node)
        self._map[key] = nil
        self._size = self._size - 1
        self._stats.misses = self._stats.misses + 1
        return nil
    end
    lfu_promote(self, node)
    self._stats.hits = self._stats.hits + 1
    return node.value
end

function LFU:peek(key)
    local node = self._map[key]
    if node == nil then return nil end
    if node.expires_at and node.expires_at <= os_time() then return nil end
    return node.value
end

function LFU:contains(key) return self:peek(key) ~= nil end

function LFU:set(key, value, ttl)
    self._stats.sets = self._stats.sets + 1
    local effective_ttl = ttl or self._default_ttl
    local expires_at = effective_ttl and (os_time() + effective_ttl) or nil
    local node = self._map[key]
    if node ~= nil then
        node.value = value
        node.expires_at = expires_at
        lfu_promote(self, node)
        return
    end
    if self._size >= self._capacity then
        -- Evict the head of the min-freq bucket.
        local b = self._buckets[self._min_freq]
        if b and b.head then
            local victim = b.head
            lfu_unlink_from(b, victim)
            self._map[victim.key] = nil
            self._size = self._size - 1
            self._stats.evictions = self._stats.evictions + 1
        end
    end
    node = { key = key, value = value, freq = 1, expires_at = expires_at }
    self._map[key] = node
    lfu_append_to(lfu_bucket(self, 1), node)
    self._min_freq = 1
    self._size = self._size + 1
end

function LFU:delete(key)
    local node = self._map[key]
    if node == nil then return false end
    local b = self._buckets[node.freq]
    lfu_unlink_from(b, node)
    self._map[key] = nil
    self._size = self._size - 1
    return true
end

function LFU:size() return self._size end

function LFU:clear()
    self._map      = {}
    self._buckets  = {}
    self._min_freq = 1
    self._size     = 0
    self._stats    = new_stats()
end

function LFU:stats()
    return {
        hits      = self._stats.hits,
        misses    = self._stats.misses,
        evictions = self._stats.evictions,
        sets      = self._stats.sets,
        size      = self._size,
        capacity  = self._capacity,
        min_freq  = self._min_freq,
    }
end

function M.lfu(capacity)
    assert(type(capacity) == "number" and capacity > 0, "cache_lru.lfu: capacity must be > 0")
    return setmetatable({
        _capacity    = capacity,
        _map         = {},
        _buckets     = {},
        _min_freq    = 1,
        _size        = 0,
        _stats       = new_stats(),
        _default_ttl = nil,
    }, LFU)
end

function M.lfu_with_ttl(capacity, default_ttl)
    local c = M.lfu(capacity)
    c._default_ttl = default_ttl
    return c
end

return M
