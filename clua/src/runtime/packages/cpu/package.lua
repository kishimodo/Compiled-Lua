return {
    name        = "cpu",
    version     = "1.0",
    description = "CPU information and utilization. Combines CPUID (vendor / brand / family / model / features / cache) with GetSystemInfo + GetLogicalProcessorInformationEx for core topology and GetSystemTimes for utilization sampling. Optional WMI fallback for clock speed and thermal-zone temperature.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cpu"] = "init.lua",
    },
    requires        = { "windows", "cpuid" },
    requires_native = {},
}
