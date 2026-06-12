return {
    name        = "tree",
    version     = "1.0",
    description = "Tree walking + size accounting. Iterator over a directory tree yielding {path, depth, is_dir, size}; du() rolls up sizes; find() filters with a predicate. Tracks visited inodes to handle reparse-point loops safely.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tree"] = "init.lua",
    },
    requires        = { "fs", "path" },
    requires_native = {},
}
