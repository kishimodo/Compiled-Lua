return {
    name        = "cobs",
    version     = "1.0",
    description = "Consistent Overhead Byte Stuffing -- COBS framing per Cheshire/Baker 1999. Eliminates zero bytes from payloads to enable unambiguous packet framing on streaming transports (UART, TCP framed protocols). Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cobs"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
