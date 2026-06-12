return {
    name        = "wmi",
    version     = "0.1",
    description = "WMI (Windows Management Instrumentation) query API via SWbemLocator over COM. Run WQL queries, fetch class instances, invoke methods, and inspect properties. Convenience wrappers for the common collections: processes, services, disks, network adapters, installed software.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["wmi"] = "init.lua",
    },
    requires        = { "windows", "windows.com" },
    requires_native = {},
}
