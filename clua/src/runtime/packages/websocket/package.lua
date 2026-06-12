return {
    name        = "websocket",
    version     = "0.1",
    description = "RFC 6455 WebSocket client + server with control-frame handling, continuation reassembly, and RFC 7692 permessage-deflate when zlib is available. Built on `socket` for TCP, `tls_client` for wss, and `http` for the handshake / server upgrade path.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["websocket"] = "init.lua",
    },
    requires        = { "socket", "tls_client", "http" },
    requires_native = {},
}
