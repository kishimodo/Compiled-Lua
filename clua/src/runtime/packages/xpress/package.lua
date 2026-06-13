return {
    name        = "xpress",
    version     = "1.0",
    description = "Windows-native compression via ntdll RtlCompressBuffer / RtlDecompressBufferEx. Exposes COMPRESSION_FORMAT_LZNT1 (2), XPRESS (3) and XPRESS_HUFF (4 -- the format used by the CLua package loader). Single-shot compress(bytes, format?) / decompress(bytes, format, original_size) plus a framed variant that embeds magic + format + original-length so the decompressor can recover both. Zero external dependencies -- ntdll ships on every Windows install.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["xpress"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
