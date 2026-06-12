return {
    name        = "secret",
    version     = "1.0",
    description = "Security utilities for handling sensitive bytes. Constant-time memcmp, volatile-pointer wipe (defeats the dead-store optimizer), VirtualLock/VirtualUnlock helpers to keep a buffer off the paging file, and a redact() helper that produces a safe-for-logs version of a string.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["secret"] = "init.lua",
    },
    requires        = { "windows", "windows.memory" },
    requires_native = {},
}
