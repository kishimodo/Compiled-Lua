return {
    name        = "brotli",
    version     = "1.0",
    description = "Brotli (RFC 7932) compression bindings via brotli.dll. One-shot surface: compress(bytes, opts?) and decompress(bytes); streaming surface: compressor(opts?) and decompressor() each yielding objects with :write / :read / :finish. opts: { quality = 0..11 (default 11), mode = 'generic'|'text'|'font', lgwin = 10..24 (default 22), lgblock = 16..24 }. Loads brotli.dll lazily from $LUAVM_BROTLI_DLL or common names (brotli, brotlienc / brotlidec, libbrotlienc / libbrotlidec). Auto-detects whether the DLL is a unified build or split enc/dec libs.",
    license     = "MIT (bindings), MIT (Brotli upstream)",
    main        = "init.lua",
    modules     = {
        ["brotli"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "brotli.dll", mode_default = "embed", env_var = "LUAVM_BROTLI_DLL" },
    },
}
