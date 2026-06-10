return {
    name        = "prompt",
    version     = "1.0",
    description = "Interactive question helpers: input, password (no echo), confirm, number with validators, single-select, multi-select with checkboxes. All prompts honor Ctrl-C cancellation (return nil). Page-scrolls for long lists.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["prompt"] = "init.lua",
    },
    requires        = { "color", "term", "keyboard" },
    requires_native = {},
}
