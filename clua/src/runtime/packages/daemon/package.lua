return {
    name        = "daemon",
    version     = "0.1",
    description = "Windows service helpers over windows.services: install / uninstall / start / stop / status from an admin script, and run_as_service(handler) from inside the service binary itself.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["daemon"] = "init.lua",
    },
    requires        = { "windows", "windows.services" },
    requires_native = {},
}
