return {
    name        = "atomic",
    version     = "0.2",
    description = "Atomic int32 / int64 / pointer / flag cells backed by Win32 Interlocked* intrinsics. Lock-free fetch-add, compare-and-swap, swap, bitwise-and/or, increment/decrement. Sequentially consistent. Cells expose :address() so they can be shared across OS threads.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["atomic"] = "init.lua",
    },
    requires        = { "windows", "windows.threading" },
    requires_native = {},
}
