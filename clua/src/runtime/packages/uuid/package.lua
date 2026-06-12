return {
    name        = "uuid",
    version     = "1.0",
    description = "UUID v1/v3/v4/v5/v6/v7 (RFC 4122 + draft -ietf-uuidrev-rfc4122bis) plus ULID, KSUID, and Nano ID. Parse/format helpers. Uses the random package's CSPRNG and the hash package for v3 (MD5) and v5 (SHA-1).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["uuid"] = "init.lua",
    },
    requires        = { "random", "hash" },
    requires_native = {},
}
