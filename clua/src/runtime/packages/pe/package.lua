return {
    name        = "pe",
    version     = "1.0",
    description = "Portable Executable (PE32 / PE32+) parser in pure Lua. Reads DOS header, NT headers, optional header (both bitnesses), section table, import directory (per-DLL function lists), export directory (named + ordinal), resource tree (recursive), relocations, debug directory, certificate table (Authenticode/WIN_CERTIFICATE blobs), TLS callbacks, and ASCII strings >= N bytes from .rdata/.data. Accepts file paths or raw byte strings. No native deps.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["pe"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
