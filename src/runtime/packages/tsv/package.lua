return {
    name        = "tsv",
    version     = "1.0",
    description = "Tab-separated values: thin wrapper over the csv package with delimiter='\\t'. Same API surface (decode/encode/reader/writer).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tsv"] = "init.lua",
    },
    requires        = { "csv" },
    requires_native = {},
}
