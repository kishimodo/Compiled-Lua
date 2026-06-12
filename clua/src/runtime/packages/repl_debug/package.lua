return {
    name        = "repl_debug",
    version     = "1.0",
    description = "Step debugger for Lua. Breakpoints by file:line (with optional condition), step in/over/out, watch expressions, stack navigation (up/down/frame), and a live prompt with locals/upvalues/globals inspection plus arbitrary expression evaluation in the paused frame. Built on debug.sethook + debug.getlocal/getupvalue; uses the inspect package for pretty values and integrates with the repl package for line editing.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["repl_debug"] = "init.lua",
    },
    requires        = { "inspect", "repl" },
    requires_native = {},
}
