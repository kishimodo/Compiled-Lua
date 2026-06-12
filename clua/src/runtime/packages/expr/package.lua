return {
    name        = "expr",
    version     = "1.0",
    description = "Sandboxed expression evaluator. Recursive-descent parser for arithmetic, comparison, boolean, string-concat and table-indexing expressions. Compiles to a restricted Lua chunk loaded with a deny-by-default env -- no loops, no definitions, no globals, no metatables. Function calls limited to an explicit allowlist. Provides both a compile-to-function low-level API and a compile_evaluator() object with :eval(context), :variables(), and :source() helpers. Pure Lua, no native deps.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["expr"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
