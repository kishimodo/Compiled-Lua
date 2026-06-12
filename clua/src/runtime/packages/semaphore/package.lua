return {
    name        = "semaphore",
    version     = "0.2",
    description = "Counting semaphore via Win32 CreateSemaphoreW. Bounded by max count, timed acquire / batch release, atomic try_acquire(n) with roll-back on partial, semaphore.with(s, fn) RAII wrapper, and best-effort value tracking. Named variant for cross-process synchronization.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["semaphore"] = "init.lua",
    },
    requires        = { "windows", "windows.threading", "atomic" },
    requires_native = {},
}
