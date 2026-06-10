return {
    name        = "slug",
    version     = "1.0",
    description = "Make URL-safe slugs from arbitrary Unicode strings. slugify() lowercases, transliterates Latin-Extended diacritics back to ASCII, replaces remaining non-alphanumeric runs with a separator, deduplicates separators, and clamps to a max length. unicode_slug() keeps non-Latin scripts intact so callers can produce search-friendly slugs in CJK / Arabic / Cyrillic content.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["slug"] = "init.lua",
    },
    requires        = { "unicode" },
    requires_native = {},
}
