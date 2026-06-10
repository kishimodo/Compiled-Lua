return {
    name        = "querystring",
    version     = "1.0",
    description = "application/x-www-form-urlencoded query-string codec. Repeated keys collected into Lua arrays; '+' decodes to space. encode/decode work on map-style tables, decode_array/encode_array work on ordered (key,value) pair lists. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["querystring"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
