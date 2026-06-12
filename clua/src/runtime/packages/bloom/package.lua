return {
    name        = "bloom",
    version     = "1.0",
    description = "Probabilistic set-membership data structures. Classic Bloom filter (m-bit array, k hash functions, optimal sizing from expected_items + false_positive_rate), Counting Bloom filter (4-bit counters per slot, supports remove), and Cuckoo filter (two-choice fingerprint table with kick-out, supports true deletion). FNV-1a + double-hashing for the k positions. Round-trip serialize/deserialize.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["bloom"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
