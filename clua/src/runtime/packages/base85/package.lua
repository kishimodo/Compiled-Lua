return {
    name        = "base85",
    version     = "1.0",
    description = "Base85 encoder + decoder. Two variants: RFC 1924 (IPv6 alphabet, no delimiters) and Adobe Ascii85 (with <~ ... ~> delimiters and 'z' shorthand for an all-zero 32-bit word). Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["base85"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
