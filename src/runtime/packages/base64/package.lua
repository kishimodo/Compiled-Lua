return {
    name        = "base64",
    version     = "1.0",
    description = "Base64 encoder + decoder. RFC 4648 section 4 standard alphabet and section 5 URL-safe alphabet. Padding optional on decode, configurable on encode. Strict input validation. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["base64"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
