return {
    name        = "dotnet",
    version     = "0.1",
    description = "In-memory .NET Framework CLR hosting via mscoree + mscorlib COM",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["dotnet"] = "init.lua",
    },
    requires        = {},   -- uses ffi.load("mscoree", "oleaut32") at runtime
    requires_native = {},
}
