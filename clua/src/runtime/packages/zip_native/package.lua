return {
    name        = "zip_native",
    version     = "1.0",
    description = "High-performance ZIP archive reader + writer via libzip.dll. API parity with our pure-Lua zip package -- open(path) returns reader with :list / :read / :extract_all; create(path) returns writer with :add_file / :add_path / :close -- but delegates to libzip for native-speed compression / decompression and big-archive handling. Loads libzip.dll lazily from $LUAVM_LIBZIP_DLL or common names; raises a descriptive error if absent. Useful for callers who care about throughput; the pure-Lua zip package remains the zero-dependency fallback.",
    license     = "MIT (bindings), BSD-3 (libzip upstream)",
    main        = "init.lua",
    modules     = {
        ["zip_native"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "libzip.dll", mode_default = "embed", env_var = "LUAVM_LIBZIP_DLL" },
    },
}
