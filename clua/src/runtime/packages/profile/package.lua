return {
    name        = "profile",
    version     = "1.0",
    description = "Sampling profiler for Lua. Uses debug.sethook count hooks (calibrated against measured instructions/sec) to grab stacks at a configurable rate. Aggregates into a hot-tree, Brendan Gregg folded flame-graph text, Chrome trace-event JSON (chrome://tracing), and an approximate pprof JSON rendering. start/stop or with(fn) RAII.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["profile"] = "init.lua",
    },
    requires        = { "json" },
    requires_native = {},
}
