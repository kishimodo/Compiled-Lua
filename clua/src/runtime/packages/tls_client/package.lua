return {
    name        = "tls_client",
    version     = "0.1",
    description = "TLS 1.2/1.3 client over Windows SChannel (secur32.dll). Cert verification, ALPN, SNI, custom CA roots. Drop-in for `socket` -- same read/write/close shape on the returned conn so http/redis/smtp can use it transparently for the encrypted leg.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["tls_client"] = "init.lua",
    },
    -- SChannel lives in secur32.dll (Security Service Provider Interface);
    -- the underlying socket transport comes from `socket`.
    requires        = { "windows", "socket" },
    requires_native = {},
}
