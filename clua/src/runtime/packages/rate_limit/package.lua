return {
    name        = "rate_limit",
    version     = "2.0",
    description = "Token bucket, leaky bucket, sliding window, fixed window rate limiters. token_bucket({capacity, refill_rate, refill_interval_ms}) / leaky_bucket({capacity, leak_rate, leak_interval_ms}) / sliding_window({max_requests, window_ms}) / fixed_window({max_requests, window_ms}). All limiters expose :take(n?) -> ok, retry_after_ms, :available(), :wait(n?, timeout_ms?), :reset(). keyed(make_limiter_fn) wraps any constructor for per-key sharding. Optional mutex integration (uses 'mutex' package if available).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["rate_limit"] = "init.lua",
    },
    requires        = { "time" },
    requires_native = {},
}
