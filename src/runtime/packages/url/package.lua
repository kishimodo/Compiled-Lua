return {
    name        = "url",
    version     = "1.0",
    description = "URL parser + formatter per RFC 3986. Splits scheme / userinfo / host / port / path / query / fragment, with per-component percent-encoding (each component honours its own reserved set). Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["url"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
