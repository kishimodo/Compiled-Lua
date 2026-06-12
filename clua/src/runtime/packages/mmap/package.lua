return {
    name        = "mmap",
    version     = "1.0",
    description = "Memory-mapped files via CreateFileMappingW + MapViewOfFile. Supports read, read/write, and copy-on-write. Object surface: :size(), :read(off, len), :write(off, bytes), :slice(off, len) -> bounded cdata pointer, :flush(off?, len?), :as_string(), :close().",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["mmap"] = "init.lua",
    },
    requires        = { "windows", "windows.filesystem", "windows.memory", "path" },
    requires_native = {},
}
