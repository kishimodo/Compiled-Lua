return {
    name        = "hll",
    version     = "1.0",
    description = "HyperLogLog cardinality estimator. Memory-efficient unique-counting at fixed cost (precision p uses 2^p 6-bit registers, e.g. p=14 = ~16 KB for ~0.8% error). Implements the harmonic-mean estimator with LinearCounting bias correction for small ranges and the Google HLL++ bias subtraction tables for the medium range. Supports merge (set-union of two HLLs) and round-trip serialize/deserialize.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["hll"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
