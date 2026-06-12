return {
    name        = "ini",
    version     = "1.0",
    description = "Classic INI file decoder + encoder. [sections], key=value (also key: value), ';' and '#' comments, escape sequences (\\n, \\t, \\\\, \\\", \\xNN), quoted values, top-level (sectionless) keys, duplicate-key array promotion. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["ini"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
