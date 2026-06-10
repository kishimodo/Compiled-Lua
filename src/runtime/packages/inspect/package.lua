return {
    name        = "inspect",
    version     = "1.0",
    description = "Pretty-printer for arbitrary Lua values: tables (with cycle detection via @N markers), functions (source file + line via debug.getinfo), cdata (type + scalar value or pointer address + optional byte dump), threads, userdata. Stable, sorted-key output suitable for snapshot tests. Inline-vs-multiline auto-collapse, depth limit, configurable string truncation, optional ANSI color, configurable cycle marker style.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["inspect"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
