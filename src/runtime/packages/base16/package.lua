return {
    name        = "base16",
    version     = "1.0",
    description = "Base16 (hex) encoder + decoder. Uppercase or lowercase emit; case-insensitive decode. Whitespace tolerant on decode. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["base16"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
