return {
    name        = "event",
    version     = "0.2",
    description = "Win32 kernel-event wrapper (CreateEventW). event.manual()/event.auto() constructors, pulse() for release-all-then-reset, named events for cross-process signalling, and wait_any / wait_all helpers backed by WaitForMultipleObjects.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["event"] = "init.lua",
    },
    requires        = { "windows", "windows.threading" },
    requires_native = {},
}
