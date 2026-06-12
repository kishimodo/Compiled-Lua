return {
    name        = "json",
    version     = "1.0",
    description = "JSON encoder + decoder. Full RFC 8259 surface: numbers (int/float), strings (UTF-8, escape sequences, surrogate pairs), arrays, objects, booleans, null. Streaming decode via a coroutine-friendly entry. Pretty-print + compact emit. Schema-light validation (type/min/max/enum/required). No external deps -- pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["json"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
