return {
    name        = "mem",
    version     = "1.0",
    description = "Cross-process memory read/write/protect/query + CE-style AOB pattern scanning (with ?? wildcards) for the current process or a remote process. Wraps OpenProcess + Read/WriteProcessMemory + VirtualQueryEx + VirtualProtectEx. Includes self_read / self_write shortcuts for the current process, mem.scan(proc, pattern) returning all matches, and a compiled-pattern cache.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["mem"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
