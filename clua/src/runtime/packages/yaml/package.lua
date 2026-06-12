return {
    name        = "yaml",
    version     = "1.0",
    description = "YAML 1.2 subset decoder + encoder. JSON-superset, block mappings/sequences, flow mappings/sequences, block scalars (| and >), anchors (&) and aliases (*), explicit !!type tags, multi-document streams (---/...). Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["yaml"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
