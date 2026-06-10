return {
    name        = "metrics",
    version     = "1.0",
    description = "Prometheus/StatsD metric registry: counters, gauges, histograms (cumulative buckets), summaries (reservoir-sampled quantiles), all with labels for per-series resolution. Exporters: Prometheus text exposition format (HELP/TYPE + le/quantile labels), StatsD UDP datagrams. Includes a time() helper for observing function durations.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["metrics"] = "init.lua",
    },
    requires        = { "socket" },
    requires_native = {},
}
