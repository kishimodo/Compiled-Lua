return {
    name        = "docx",
    version     = "1.0",
    description = "Microsoft Word .docx reader + writer. A .docx is a ZIP containing word/document.xml (WordprocessingML); this package opens the archive, parses the main document part, the relationships, and the media folder. Reader exposes paragraphs (with runs and formatting), tables, images, headers/footers, metadata. Writer constructs a minimal but valid Office-Open-XML document with paragraphs, tables, images, and page breaks. Uses the zip + xml packages.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["docx"] = "init.lua",
    },
    requires        = { "zip", "xml" },
    requires_native = {},
}
