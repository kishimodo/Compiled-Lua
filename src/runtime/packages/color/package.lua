return {
    name        = "color",
    version     = "1.0",
    description = "ANSI styling: 16-color, 256-color, and truecolor helpers with Windows VT-processing enable. Honors NO_COLOR / FORCE_COLOR. Nested-style composition (red(bold(s)) restores the outer color after the inner reset). Strip helper for measuring visible width.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["color"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
