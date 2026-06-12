return {
    name        = "cron_expr",
    version     = "1.0",
    description = "Standalone cron expression parser, analyser and humaniser. Standard 5-field minute/hour/dom/mon/dow plus 6-field with seconds. Tokens *, comma, range, /step, L (last), W (nearest weekday), # (nth weekday of month). Named: @yearly @monthly @weekly @daily @hourly. APIs: parse + matches/next_after for scheduling, plus validate, describe (English text), simplify (canonical form), fields (per-field int lists), is_subset, union, intersection. No scheduler dependency.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cron_expr"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
