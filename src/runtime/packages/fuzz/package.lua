return {
    name        = "fuzz",
    version     = "1.1",
    description = "Random input fuzzer for Lua functions. Drives a target with generated inputs from the property package, dedupes crashes by error fingerprint, shrinks each discovery to a minimal counterexample, mutates seeds, persists crash + seed corpus to disk for deterministic replay, and supports per-run timeout + max_crashes early stop. on_crash/on_progress callbacks.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["fuzz"] = "init.lua",
    },
    -- Soft dependency: fuzz reads generators produced by `property`, but the
    -- runtime side never `require`s it (the host either supplies a generator
    -- table or passes a raw fn). Listing it here lets the loader hint the user.
    requires        = { "property" },
    requires_native = {},
}
