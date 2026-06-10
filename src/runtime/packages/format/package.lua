return {
    name        = "format",
    version     = "1.0",
    description = "Lua source formatter. Tokenizes the input and re-emits with consistent style: configurable indent, unified string quotes, automatic single-line vs multi-line table layout based on width, trailing comma in multi-line tables, optional assignment alignment, trailing-whitespace strip, blank-line collapse. Output is idempotent (formatting formatted source produces no change).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["format"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
