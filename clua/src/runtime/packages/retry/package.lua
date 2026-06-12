return {
    name        = "retry",
    version     = "2.0",
    description = "Exponential backoff with jitter (full/equal/none) + circuit breaker. retry(fn, {max_attempts, initial_delay_ms, max_delay_ms, multiplier, jitter, retry_on, on_retry}) returns the value or raises 'retry: gave up after N attempts'. retry.backoff(opts) yields (attempt, delay_ms) for manual loops. circuit_breaker({failure_threshold, success_threshold, timeout_ms, half_open_max_calls}) -> cb with :call(fn, ...), :state() (closed|open|half_open), :reset(). State transitions: closed -> open on threshold failures, open -> half_open after timeout, half_open -> closed on threshold successes (or back to open on any failure).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["retry"] = "init.lua",
    },
    requires        = { "time" },
    requires_native = {},
}
