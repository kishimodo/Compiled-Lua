return {
    name        = "lint",
    version     = "1.0",
    description = "Lua linter (luacheck-lite). Tokenizes the source and walks scopes to detect unused locals, shadowed names, undefined globals (against a configurable allowlist + std library), unbalanced multi-assignment, dead code after return/break, redundant self-assignment, trailing whitespace, and probable typos (Levenshtein-based). Syntax-checks via the bundled loader. Output as text, JSON, or GitHub-Actions annotations.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["lint"] = "init.lua",
    },
    requires        = { "json" },
    requires_native = {},
}
