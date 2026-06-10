return {
    name        = "keyboard",
    version     = "1.0",
    description = "Raw keypress reader on top of ReadConsoleInputW: F-keys, arrows, Ctrl/Alt/Shift modifiers, named keys. Includes a line editor (read_line) with history, arrow navigation, and tab completion, plus a wait_for helper for menus.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["keyboard"] = "init.lua",
    },
    requires        = { "windows", "color" },
    requires_native = {},
}
