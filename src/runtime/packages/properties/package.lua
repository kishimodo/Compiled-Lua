return {
    name        = "properties",
    version     = "1.0",
    description = "Java .properties decoder + encoder. key=value / key:value / key value separators, ! and # comment markers, backslash line continuation, \\uXXXX unicode escapes, trimmed keys, preserved-whitespace values. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["properties"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
