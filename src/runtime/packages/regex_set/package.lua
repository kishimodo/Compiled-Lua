return {
    name        = "regex_set",
    version     = "1.0",
    description = "Aho-Corasick multi-pattern string matcher. Compiles many literal-string needles into a single goto + failure-link automaton, then scans an input text in O(n + m + k) (input length + total pattern length + number of hits). Reports every occurrence of every pattern with its position, supports membership-only and pattern-index queries, and an optional case-insensitive mode.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["regex_set"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
