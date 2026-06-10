return {
    name        = "varint",
    version     = "1.0",
    description = "Variable-length integer codec -- protobuf-compatible LEB128. Unsigned 64-bit + zigzag-signed variants. Streaming-friendly decode returns the new position. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["varint"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
