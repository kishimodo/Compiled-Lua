return {
    name        = "epub",
    version     = "1.0",
    description = "EPUB ebook reader + writer (EPUB 2 + 3). EPUB is a ZIP whose META-INF/container.xml points at the OPF package document; this package walks that pointer chain, parses the manifest / spine / metadata, extracts XHTML chapters, the cover image, and the table of contents (NCX for EPUB 2, nav.xhtml for EPUB 3). Writer constructs a minimal but valid EPUB 3 archive with chapters, cover, and TOC. Uses zip + xml packages.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["epub"] = "init.lua",
    },
    requires        = { "zip", "xml" },
    requires_native = {},
}
