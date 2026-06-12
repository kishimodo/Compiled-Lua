return {
    name        = "random",
    version     = "1.0",
    description = "Unified random number generation. Crypto backend: BCryptGenRandom (CNG). Non-crypto backends: xoshiro256**, splitmix64, pcg32, mulberry32 -- pure Lua, statistically strong. Module-level bytes/int/float/choice/shuffle use CSPRNG by default; random.seed(n) switches them to a deterministic xoshiro256**. random.prng(name, seed) constructs a stateful PRNG object exposing :uint64/:uint32/:double/:bytes/:range/:choice/:shuffle.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["random"] = "init.lua",
    },
    requires        = { "windows", "windows.bcrypt" },
    requires_native = {},
}
