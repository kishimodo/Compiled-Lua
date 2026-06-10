return {
    name        = "tty",
    version     = "0.1",
    description = "Terminal control: raw mode, size, VT-processing toggle, cursor / clear / move / set_title, color-capability detection, SGR builder.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tty"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
