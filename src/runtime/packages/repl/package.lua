return {
    name        = "repl",
    version     = "1.0",
    description = "Embeddable Lua REPL with multiline detection (balanced parens/brackets/braces and matched do/end/function/end pairs), persistent history, tab completion via env walking, optional syntax coloring, and a custom on_eval hook for embedding into non-Lua DSL hosts.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["repl"] = "init.lua",
    },
    requires        = { "color", "keyboard" },
    requires_native = {},
}
