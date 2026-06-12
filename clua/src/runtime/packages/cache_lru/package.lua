return {
    name        = "cache_lru",
    version     = "1.0",
    description = "In-memory LRU and LFU caches. LRU is a classical doubly-linked list + hash table with O(1) get/set/evict. LFU uses the O(1) min-frequency-bucket algorithm: per-count linked lists, tracked min freq, evicts the head of the min bucket. Both support optional per-entry TTL (lazy expiry on access) and report hits/misses/evictions stats. Thread-unsafe -- pair with the mutex package for cross-thread sharing.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cache_lru"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
