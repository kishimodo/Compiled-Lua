return {
    name        = "ndjson",
    version     = "1.0",
    description = "Newline-Delimited JSON (NDJSON / JSON Lines). One JSON value per line. Streaming iterator decode, batch decode, encoder that serializes a sequence of values. Built on the json package.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["ndjson"] = "init.lua",
    },
    requires        = { "json" },
    requires_native = {},
}
