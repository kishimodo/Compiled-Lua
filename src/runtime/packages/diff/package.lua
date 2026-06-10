return {
    name        = "diff",
    version     = "1.0",
    description = "Myers diff (1986) over line / word / character sequences. diff_lines() returns a structured edit script tagged with kind=ctx|add|del + 1-based source / destination line numbers. unified() renders the script in standard unified-diff format with @@ hunk headers and configurable context. word_diff() and char_diff() reuse the same core for finer-grained editing operations. apply() takes an a-string + an edit script and reconstructs the b-string.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["diff"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
