return {
    name        = "pdf_write",
    version     = "1.0",
    description = "PDF 1.7 generator. Pure-Lua emitter for pages with text (Helvetica/Times/Courier with bold/italic variants), vector graphics (lines, rects, circles, curves), embedded images (JPEG passthrough, PNG via FlateDecode), hyperlinks and bookmarks. Constructs the cross-reference table, indirect objects, content streams, and trailer. Optional FlateDecode of content streams via the zlib package (soft).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["pdf_write"] = "init.lua",
    },
    requires        = { "zlib" },
    requires_native = {},
}
