return {
    name        = "tempdir",
    version     = "1.0",
    description = "RAII temp files and directories with automatic cleanup. Files registered with a finalizer that removes them on object collection; an additional process-exit hook scrubs whatever is still tracked. Includes with_tempdir(fn) for scoped use.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tempdir"] = "init.lua",
    },
    requires        = { "windows", "windows.filesystem", "fs", "path" },
    requires_native = {},
}
