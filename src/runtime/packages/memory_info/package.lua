return {
    name        = "memory_info",
    version     = "1.0",
    description = "System and per-process memory information. Wraps GlobalMemoryStatusEx for the system view and GetProcessMemoryInfo / QueryWorkingSetEx for per-process counters. Working-set detail walks PSAPI_WORKING_SET_EX_INFORMATION pages.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["memory_info"] = "init.lua",
    },
    requires        = { "windows", "windows.psapi" },
    requires_native = {},
}
