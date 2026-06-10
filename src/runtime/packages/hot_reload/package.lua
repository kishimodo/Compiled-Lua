return {
    name        = "hot_reload",
    version     = "1.0",
    description = "Module hot-swap on file change. Watches Lua modules (or raw files) and re-requires them when the source mtime changes; patches the loaded table in place so live references keep working. Optional keep_state/apply_state callbacks bridge old state to the new module. Uses the watcher package for push notifications when available, else falls back to scheduler-driven polling, else manual tick().",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["hot_reload"] = "init.lua",
    },
    requires        = { "fs", "watcher", "scheduler" },
    requires_native = {},
}
