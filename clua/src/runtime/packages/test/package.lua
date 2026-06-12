return {
    name        = "test",
    version     = "1.0",
    description = "BDD-style test runner: describe/it with nested suites, before/after_each, before/after_all, pending, tags, only/skip, name-pattern filter, bail, async tests via done callback + timeout, and four reporters (spec, tap, junit-xml, json). Optional parallelisation via the pool package when present.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["test"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
