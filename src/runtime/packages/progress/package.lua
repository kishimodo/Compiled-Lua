return {
    name        = "progress",
    version     = "1.0",
    description = "Progress bars + spinners with EMA-smoothed ETA, configurable format strings, and a multi-bar manager that repaints concurrent bars to fixed rows. Writes to stderr by default so progress output never contaminates piped stdout.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["progress"] = "init.lua",
    },
    requires        = { "windows", "color", "term" },
    requires_native = {},
}
