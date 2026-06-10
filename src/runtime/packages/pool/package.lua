return {
    name        = "pool",
    version     = "0.1",
    description = "Worker pool with a bounded task queue and future-based result handoff. submit() returns a future whose :result(timeout_ms?) blocks until the worker completes. :map(fn, items) and the standalone pool.parallel(fn, items) cover the common parallel-foreach case. Degrades to inline dispatch when the thread package falls back to cooperative mode -- the API surface stays identical.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["pool"] = "init.lua",
    },
    requires        = { "thread", "channel", "atomic" },
    requires_native = {},
}
