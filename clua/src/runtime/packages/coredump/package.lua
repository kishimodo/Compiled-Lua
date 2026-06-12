return {
    name        = "coredump",
    version     = "1.0",
    description = "Minidump reader + writer. Reader: parses the MINIDUMP_HEADER + directory entries directly from disk; surfaces thread contexts, loaded modules, memory ranges, the exception record (if present), and SystemInfo. Writer: wraps MiniDumpWriteDump for the current process with configurable detail flags. Reader is pure Lua against the raw file; writer requires dbghelp.dll (loaded lazily, so a reader-only consumer still works without dbghelp).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["coredump"] = "init.lua",
    },
    requires        = { "windows", "windows.dbghelp" },
    requires_native = {},
}
