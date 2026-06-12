return {
    name        = "property",
    version     = "1.0",
    description = "QuickCheck-style property testing with deterministic xorshift64 PRNG and counterexample shrinking. Generators: int, string, bool, float, array_of, record, one_of, frequency, map, filter, recursive. check() returns a result with the shrunk minimal counterexample, seed for replay, and shrink count.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["property"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
