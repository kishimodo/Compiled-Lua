return {
    name        = "cache_ttl",
    version     = "1.0",
    description = "TTL-based expiry cache. Lazy expiry on get/contains plus opportunistic 64-entry partial sweep amortized across reads. :cleanup() runs a full pass on demand (use a scheduler tick for periodic invocation). Capacity overflow evicts the entry with the soonest expiry. Surface: new, get, set (per-call ttl override), delete, touch, expires_at, contains, peek, size, cleanup, stats, clear, pairs. Pure Lua, no native deps.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cache_ttl"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
