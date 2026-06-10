return {
    name        = "hash",
    version     = "1.0",
    description = "Unified hash API. Backends: MD5 + SHA-1/256/384/512 + SHA3-256/384/512 via Windows CNG (BCrypt; SHA-3 needs Win10 1903+). CRC32 (table-driven, pure Lua). xxHash32 + xxHash64 (full spec, pure Lua). BLAKE3 (full chunk-tree, pure Lua). One-shots return hex; <algo>_raw returns binary. Streaming :update/:digest/:hexdigest object. File helpers stream a path in 64 KiB chunks.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["hash"] = "init.lua",
    },
    requires        = { "windows", "windows.bcrypt" },
    requires_native = {},
}
