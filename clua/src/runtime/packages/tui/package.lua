return {
    name        = "tui",
    version     = "1.0",
    description = "Curses-like terminal UI: double-buffered render with O(changed) diffing, focus management, layout primitives (vbox/hbox/grid/border), and widgets (text, input, button, list, table, progress). Uses windows.console for keyboard input and ANSI VT for output.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tui"] = "init.lua",
    },
    requires        = { "windows", "color", "term", "keyboard" },
    requires_native = {},
}
