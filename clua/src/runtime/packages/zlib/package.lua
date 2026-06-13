return {
    name        = "zlib",
    version     = "1.0",
    description = "DEFLATE (RFC 1951) + zlib (RFC 1950) + gzip (RFC 1952) compress / decompress. Unified compress(bytes, level?, format?) entry with format = 'deflate' | 'zlib' | 'gzip'. Pure-Lua implementation that auto-promotes to system zlib1.dll / zlibwapi.dll when present (5-50x faster on large inputs). Decoder covers all DEFLATE block types (stored, fixed huffman, dynamic huffman). Encoder produces stored blocks at level 0 and LZ77+Huffman at levels 1-9. Streaming compressor + decompressor objects via :update / :final. CRC-32 and Adler-32 helpers exposed.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["zlib"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "zlib1.dll", mode_default = "embed", env_var = "CLUA_ZLIB_DLL" },
    },
}
