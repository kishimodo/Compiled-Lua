return {
    name        = "env",
    version     = "0.1",
    description = "Windows environment-variable wrapper: get / set / unset / expand / list / scoped with-block. Operates on the W (UTF-16) APIs internally; Lua strings are UTF-8.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["env"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
