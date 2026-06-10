return {
    name        = "pipe",
    version     = "0.1",
    description = "Win32 anonymous (CreatePipe) and named (CreateNamedPipeW / ConnectNamedPipe) pipes. Pipe objects with :read/:write/:close. Server :accept() and client connect with optional wait timeout.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["pipe"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
