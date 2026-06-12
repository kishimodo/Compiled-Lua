return {
    name        = "wcwidth",
    version     = "1.0",
    description = "Display-cell width of a Unicode codepoint or UTF-8 string in a fixed-width terminal. Markus Kuhn's algorithm, table-updated for Unicode 15. Combining marks return 0, East-Asian Wide and Fullwidth return 2, control characters return -1, everything else returns 1. swidth() sums across an entire string while stripping ANSI CSI / OSC escape sequences so callers can measure colored or styled output verbatim.",
    license     = "MIT (LuaVM glue), public domain (Kuhn algorithm)",
    main        = "init.lua",
    modules     = {
        ["wcwidth"] = "init.lua",
    },
    requires        = { "unicode" },
    requires_native = {},
}
