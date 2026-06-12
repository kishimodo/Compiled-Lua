-- LuaVM display package manifest.
return {
    name        = "display",
    version     = "0.1",
    description = "Monitor / display enumeration: EnumDisplayMonitors + GetMonitorInfoW + GetDpiForMonitor + EnumDisplaySettingsW. Reports geometry (rect / work-area), DPI / scale, current mode, and supported modes per adapter.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["display"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
