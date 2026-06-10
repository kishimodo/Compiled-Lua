return {
    name        = "async",
    version     = "0.1",
    description = "Coroutine-driven event loop: file I/O, TCP/UDP, subprocesses, timers",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["async"] = "init.lua",
    },
    requires        = { "windows" },   -- uses ffi.C kernel32 + ws2_32 surface
    requires_native = {},
}
