return {
    name        = "csv",
    version     = "1.0",
    description = "RFC 4180 CSV encoder + decoder. Configurable delimiter, quote character, and escape style. Header-aware mode for row-as-table output. Streaming row reader for large files. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["csv"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
