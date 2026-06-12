return {
    name        = "cron",
    version     = "2.0",
    description = "Cron expression parser + next/prev/matches/iter. Supports standard 5-field (m h dom mon dow), extended 6-field with seconds, and Quartz-style 7-field with year. Tokens: '*', ',', '-', '/' step, 'L' (last), 'W' (nearest weekday), '#' (nth weekday-of-month), '?' (ignore). Named aliases @hourly @daily @midnight @weekly @monthly @yearly @annually @reboot. Named months/days. parse(expr, opts={seconds=,year=}) -> cron object with :next(from?), :prev(from?), :matches(t), :iter(from?). cron.is_valid(expr) and cron.describe(expr) for tooling.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cron"] = "init.lua",
    },
    requires        = { "time" },
    requires_native = {},
}
