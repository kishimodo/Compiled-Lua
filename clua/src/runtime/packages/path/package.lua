return {
    name        = "path",
    version     = "1.0",
    description = "Pure path manipulation, Windows-aware. Handles drive letters, UNC shares (\\\\server\\share), long-path prefix (\\\\?\\), device prefix (\\\\.\\), and mixed forward+back slashes. Case-insensitive comparison. No disk IO -- this is string surgery only; pair with the fs package for actual filesystem operations.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["path"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
