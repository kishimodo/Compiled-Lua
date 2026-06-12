return {
    name        = "rtf",
    version     = "1.0",
    description = "Rich Text Format (RTF 1.9) parser + writer. Tokenises control words, groups, escapes; folds them into a logical document model of paragraphs and runs (bold/italic/underline/font/size/color), lists, tables, images. parse() builds the doc tree, to_text() renders plain text, to_html() renders HTML. Writer constructs RTF byte-for-byte with builder methods. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["rtf"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
