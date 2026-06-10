return {
    name        = "bench",
    version     = "1.0",
    description = "Microbenchmark framework. Auto-scales batch size to a target trial duration, runs many trials, computes median/mean/stddev/min/max with Hampel-MAD outlier rejection, tracks allocations via collectgarbage('count') deltas. compare() ranks functions head-to-head with x-times-slower factors. suite()/:add/:run/:report for grouped runs.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["bench"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
