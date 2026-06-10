return {
    name        = "punycode",
    version     = "1.0",
    description = "Punycode (RFC 3492) -- IDN label encoder / decoder. Plus full to_ascii / to_unicode wrappers that handle UTF-8 input/output and the 'xn--' label prefix per dot-separated domain segment. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["punycode"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
