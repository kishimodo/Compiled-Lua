return {
    name        = "tracing",
    version     = "1.0",
    description = "OpenTelemetry-style distributed tracing: tracers, spans with attributes/events/status, parent-child links, sampling (always/never/ratio/parent_or), exporters (stdout-json, OTLP/HTTP JSON, Jaeger HTTP JSON, Zipkin v2 JSON), W3C traceparent propagate/extract, RAII with_span(name, fn).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tracing"] = "init.lua",
    },
    requires        = { "json", "socket" },
    requires_native = {},
}
