return {
    name        = "ntp",
    version     = "0.1",
    description = "SNTP / NTPv4 client (RFC 4330 + RFC 5905 packet format). Sends client packet, parses server response, computes clock offset / round-trip delay / dispersion. Default server pool.ntp.org.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["ntp"] = "init.lua",
    },
    requires        = { "socket" },
    requires_native = {},
}
