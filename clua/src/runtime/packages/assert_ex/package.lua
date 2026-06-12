return {
    name        = "assert_ex",
    version     = "1.0",
    description = "Rich assertion library with deep-equal, structural shape checks, and a fluent expect() chain. Named assert_ex so it does not clobber Lua's built-in assert. Failed deep-equal emits a path-localised diff showing what differs. Pure Lua, no deps.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["assert_ex"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
