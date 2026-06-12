return {
    name        = "toml",
    version     = "1.0",
    description = "TOML 1.0 parser + writer. Tables, inline tables, arrays of tables, basic/literal/multiline strings, datetime/date/time, integers (hex/oct/bin/underscores), floats (inf/nan), comments. Round-trip safe. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["toml"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
