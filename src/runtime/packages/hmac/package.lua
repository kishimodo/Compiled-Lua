return {
    name        = "hmac",
    version     = "1.0",
    description = "HMAC (RFC 2104) keyed-hash MAC. Works over any algorithm exposed by the hash package: md5, sha1, sha256, sha384, sha512, blake3. Block-size aware key normalisation. Streaming :update/:final/:final_hex object plus hmac.<algo>(key, msg) one-shots.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["hmac"] = "init.lua",
    },
    requires        = { "hash" },
    requires_native = {},
}
