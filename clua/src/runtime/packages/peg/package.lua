return {
    name        = "peg",
    version     = "1.0",
    description = "Pure-Lua PEG (Parsing Expression Grammar) parser combinator library. Alternative to lpeg with no native dependency. Combinators cover literal, character range, character set, any-byte, sequence, ordered alternation, kleene-star, one-or-more, optional, negative + positive lookahead, plain + string captures, position captures, named group captures, and forward-reference rules via ref(). Common building-block helpers for whitespace, identifiers, numbers, and quoted strings. Grammar wrapper accepts a table of named rules and a start rule.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["peg"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
