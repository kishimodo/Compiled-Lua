return {
    name        = "term",
    version     = "1.0",
    description = "Cursor positioning, screen clearing, alt-screen, scrolling regions via ANSI VT sequences. Pairs with the color package for the one-time VT enable. Size query goes through the Windows console API with env-var fallback.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["term"] = "init.lua",
    },
    requires        = { "windows", "color" },
    requires_native = {},
}
