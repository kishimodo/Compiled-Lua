-- CLua wndproc package manifest.
return {
    name        = "wndproc",
    version     = "0.1",
    description = "Win32 window class + message loop wrapper. Lua can register a class, create CreateWindowExW windows, install WM_* handlers, and run/peek the standard GetMessage / DispatchMessage loop. The native WndProc is a single FFI callback that fans messages out to Lua handler tables keyed by (hwnd, msg).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["wndproc"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
