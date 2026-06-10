return {
    name        = "mock",
    version     = "1.0",
    description = "Function spies, stubs, and fakes for unit tests. Records every call, supports queued returns, matcher-based when().returns()/throws(), module-member replace + restore, and auto-mock objects where every key is a lazy spy. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["mock"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
