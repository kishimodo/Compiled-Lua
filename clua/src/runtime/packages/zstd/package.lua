return {
    name        = "zstd",
    version     = "1.0",
    description = "Zstandard compressor / decompressor via libzstd.dll. Single-shot compress(bytes, level?) / decompress(bytes) plus streaming compressor(opts) / decompressor() objects driven by ZSTD_compressStream2 / ZSTD_decompressStream. Dictionary training (train_dict) and dictionary-driven compress (compress_with_dict) for small-payload workloads. Default level 3; negative fast modes are passed through. Errors propagate ZSTD_getErrorName messages.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["zstd"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "libzstd.dll", mode_default = "embed", env_var = "CLUA_ZSTD_DLL" },
    },
}
