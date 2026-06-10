return {
    name        = "process",
    version     = "0.1",
    description = "Process spawn / wait / kill over CreateProcessW. Per-stream pipe / inherit / null / inline-bytes plumbing, env override, cwd, hidden window. run() blocking helper, popen() io-popen-style wrapper.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["process"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
