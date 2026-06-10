return {
    name        = "log",
    version     = "1.0",
    description = "Structured logging with 6 levels (trace..fatal), pluggable sinks (stdout/stderr/file with size+age rotation/UDP syslog/HTTP batched POST), formatters (json, logfmt, pretty text with color, RFC 5424 syslog), per-logger context via :with(), sampling (percent + token-bucket ratelimit), source-location auto-capture via debug.getinfo.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["log"] = "init.lua",
    },
    requires        = { "json", "color", "socket" },
    requires_native = {},
}
