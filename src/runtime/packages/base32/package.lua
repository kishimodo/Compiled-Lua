return {
    name        = "base32",
    version     = "1.0",
    description = "Base32 encoder + decoder. RFC 4648 section 6 standard alphabet and section 7 base32hex alphabet (extended-hex). Padding optional on decode. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["base32"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
