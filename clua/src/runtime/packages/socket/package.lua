return {
    name        = "socket",
    version     = "0.1",
    description = "High-level TCP/UDP sockets over winsock2. Blocking and non-blocking modes, line-buffered + length-framed readers, timeouts, full-duplex, DNS resolution via getaddrinfo, peer/local address introspection. Foundation for higher-level network packages (http, tls_client, dns, ntp, smtp, redis, websocket).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["socket"] = "init.lua",
    },
    requires        = { "windows" },   -- ws2_32 symbols, primitive typedefs
    requires_native = {},
}
