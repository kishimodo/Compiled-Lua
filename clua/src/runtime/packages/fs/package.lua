return {
    name        = "fs",
    version     = "1.0",
    description = "Filesystem operations -- read/write/stat/walk/glob. Builds on windows.filesystem cdefs. Writes are atomic by default (temp + rename), errors are bullet-proof (nil + clear message). UTF-16-aware long-path handling.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["fs"] = "init.lua",
    },
    requires        = { "windows", "windows.filesystem", "path", "glob" },
    requires_native = {},
}
