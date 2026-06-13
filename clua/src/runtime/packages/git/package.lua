return {
    name        = "git",
    version     = "1.0",
    description = "libgit2 bindings -- full repository manipulation: open/init/clone, walk references / branches / tags, iterate commit log, status, diff, fetch/push, checkout, index add + commit, signatures. Surface mirrors a high-level Lua-friendly facade over the C handle-and-error API. Loads git2.dll lazily via $CLUA_GIT2_DLL or common search names; raises a clear error from any operation when the DLL is absent. Auto-calls git_libgit2_init() on first use and registers an atexit-style shutdown.",
    license     = "MIT (bindings), GPLv2-with-linking-exception (libgit2 upstream)",
    main        = "init.lua",
    modules     = {
        ["git"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "git2.dll", mode_default = "embed", env_var = "CLUA_GIT2_DLL" },
    },
}
