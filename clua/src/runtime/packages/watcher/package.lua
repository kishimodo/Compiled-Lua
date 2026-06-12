return {
    name        = "watcher",
    version     = "1.0",
    description = "Filesystem change watcher via ReadDirectoryChangesW. Overlapped IO under an event handle; callers drive the watcher with :poll(timeout_ms) or :wait(handler). Buffers raw FILE_NOTIFY_INFORMATION records and decodes them into create/modify/delete/rename events.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["watcher"] = "init.lua",
    },
    requires        = { "windows", "windows.filesystem", "path" },
    requires_native = {},
}
