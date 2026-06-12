return {
    name        = "doc",
    version     = "1.0",
    description = "Doc-comment extractor for Lua source. Recognizes `--- doc` line runs and `--[[doc ... ]]` blocks; tags @param/@return/@throws/@see/@example/@since/@deprecated/@module/@field; auto-extracts function signatures from the following declaration; cross-references via [[markdown-style]] links; module index. Renders to markdown, HTML, or JSON.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["doc"] = "init.lua",
    },
    requires        = { "fs", "json" },
    requires_native = {},
}
