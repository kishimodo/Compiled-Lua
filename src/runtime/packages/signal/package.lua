return {
    name        = "signal",
    version     = "0.1",
    description = "SetConsoleCtrlHandler wrapper for Ctrl-C / Ctrl-Break / close / logoff / shutdown. Handlers register via signal.on(name, fn); returning true from the handler tells the kernel the event was handled.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["signal"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
