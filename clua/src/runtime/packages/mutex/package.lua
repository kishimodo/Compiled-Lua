return {
    name        = "mutex",
    version     = "0.2",
    description = "Cross-thread synchronization primitives: recursive mutex (CRITICAL_SECTION) with timed lock, slim reader-writer lock (SRWLOCK), and named kernel mutex for cross-process use. with_lock(m, fn) wraps RAII semantics across all three; pcall around the body guarantees release on error.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["mutex"] = "init.lua",
    },
    requires        = { "windows", "windows.threading" },
    requires_native = {},
}
