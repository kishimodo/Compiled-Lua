return {
    name        = "xml",
    version     = "1.0",
    description = "Tolerant XML 1.0 parser + writer. DOM-style parse() returns nested nodes ({tag, attrs, children}); SAX-style parse_sax() invokes callbacks. Entity decoding (named + numeric), CDATA, comments, processing instructions, XML declaration. Serializer for round-trip. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["xml"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
