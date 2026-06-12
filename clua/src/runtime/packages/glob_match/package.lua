return {
    name        = "glob_match",
    version     = "1.0",
    description = "Gitignore-style ignore-pattern matcher. compile(pattern) returns a single-pattern matcher with :match(path) -> (matched, negated). gitignore(text) compiles a full rule set with :match(path) -> (ignored, reason). Multi-line input through compile() routes to the legacy rule-set matcher with :ignored / :match for back-compat. Supports !, /, trailing-slash, *, **, ?, [abc], [!abc]. Pure pattern logic, no fs access.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["glob_match"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
