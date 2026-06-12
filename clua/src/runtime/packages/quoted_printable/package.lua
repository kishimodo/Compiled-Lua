return {
    name        = "quoted_printable",
    version     = "1.0",
    description = "Quoted-Printable encoder + decoder per RFC 2045 section 6.7. Soft line breaks at 76 characters, '=' escape for non-printable bytes, trailing whitespace protected, CRLF preserved as hard breaks. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["quoted_printable"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
