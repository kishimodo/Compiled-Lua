return {
    name        = "lz4",
    version     = "1.0",
    description = "LZ4 block + frame format compressor / decompressor. Auto-promotes to liblz4.dll for the LZ4_compress_default / LZ4_decompress_safe / LZ4F_* surface when available; falls back to a pure-Lua block + frame implementation otherwise. Unified compress(bytes, opts?) / decompress(bytes) entry produces / consumes the LZ4 frame format with optional content_size, block size, compression level, and checksum knobs. Streaming via compressor(opts) / decompressor() objects with :update / :final.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["lz4"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "liblz4.dll", mode_default = "embed", env_var = "LUAVM_LZ4_DLL" },
    },
}
