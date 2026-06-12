return {
    name        = "pdf_read",
    version     = "1.0",
    description = "PDF 1.7 parser. Locates the cross-reference table (xref or xref-stream), parses indirect objects (dictionaries, arrays, names, strings, hex strings, numbers, refs), follows the document catalog through page tree, and extracts text from page content streams (BT/ET operator interpretation: Tj, TJ, ', \"). Stream filters: FlateDecode (via zlib soft dep), ASCIIHexDecode, ASCII85Decode, LZWDecode. Exposes metadata, page enumeration, form fields, annotations, images. Pure-Lua, no Poppler. Limitations: no full vector rendering, no decryption.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["pdf_read"] = "init.lua",
    },
    requires        = { "zlib" },
    requires_native = {},
}
