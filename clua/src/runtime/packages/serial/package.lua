return {
    name        = "serial",
    version     = "1.0",
    description = "Serial port (COM) I/O. CreateFileW on \\\\.\\COMx, configured via SetCommState (baud / data bits / stop bits / parity) and SetCommTimeouts. Exposes read/write/read_line/available/flush/drain plus modem-control signals (DTR, RTS, BREAK) and signal-line reads (CTS, DSR, RING, DCD). list() enumerates ports from the registry (HKLM\\HARDWARE\\DEVICEMAP\\SERIALCOMM).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["serial"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
