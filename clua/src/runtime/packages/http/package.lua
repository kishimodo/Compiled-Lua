return {
    name        = "http",
    version     = "0.1",
    description = "HTTP/1.1 client + server in pure Lua atop `socket` (plaintext) and `tls_client` (https). Streaming bodies, chunked transfer-encoding, gzip/deflate via `zlib` when available, keep-alive connection pool, configurable redirect following, proxy support, cookies, plus a serve()/router() server.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["http"] = "init.lua",
    },
    requires        = { "socket", "tls_client" },
    requires_native = {},
}
