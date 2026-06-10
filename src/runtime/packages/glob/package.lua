return {
    name        = "glob",
    version     = "1.0",
    description = "Glob pattern matching -- compiles bash-style patterns (* ? [abc] [!abc] ** {a,b,c}) into matchers. Pure pattern logic, no filesystem walk; pair with fs.walk + glob.match for full disk globbing.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["glob"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
