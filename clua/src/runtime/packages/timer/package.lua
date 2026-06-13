return {
    name        = "timer",
    version     = "2.0",
    description = "High-precision stopwatch + periodic / one-shot scheduling. stopwatch() returns sw with :start/:stop/:reset/:lap/:elapsed/:elapsed_ms/:elapsed_ns. oneshot(delay_ms, fn) and interval(period_ms, fn, {immediate}) return handles with :cancel/:active/:next_fire. after(s, fn) and every(s, fn) are second-based shorthands. tick(period) is an iterator yielding monotonic timestamps spaced by `period`. poll()/run_forever()/sleep_until_next() drive the in-process scheduler heap (callbacks always run on the CLua main thread, never on a Win32 worker).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["timer"] = "init.lua",
    },
    requires        = { "time" },
    requires_native = {},
}
