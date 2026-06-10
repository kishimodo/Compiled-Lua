return {
    name        = "redis",
    version     = "0.1",
    description = "Redis client speaking RESP3 (with RESP2 fallback via HELLO 3). Pipelining, MULTI/EXEC transactions, pub/sub, and simple cluster awareness via MOVED redirect handling. Runs on `socket` (plaintext) or `tls_client` (rediss://).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["redis"] = "init.lua",
    },
    requires        = { "socket", "tls_client" },
    requires_native = {},
}
