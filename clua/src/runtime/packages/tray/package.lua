-- CLua tray package manifest.
return {
    name        = "tray",
    version     = "0.1",
    description = "System tray icons + popup menus via Shell_NotifyIconW. Manages a hidden message-only window so click / menu / balloon events flow back through a Lua callback table. Supports nested submenus, separators, balloons (notify), and standard left/right/double-click bindings.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tray"] = "init.lua",
    },
    requires        = { "windows", "wndproc" },
    requires_native = {},
}
