return {
    name        = "jwt",
    version     = "1.0",
    description = "JSON Web Token (RFC 7519). Sign and verify with HS256/384/512 (HMAC), RS256/384/512 (RSA-PKCS1v1.5 via CNG), PS256/384/512 (RSA-PSS via CNG), ES256/384/512 (ECDSA via CNG). Standard claims validation (exp/nbf/iat/iss/aud) with leeway. decode_unverified() for token inspection. Base64url helpers and tolerant decoding.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["jwt"] = "init.lua",
    },
    requires        = { "json", "hash", "hmac", "windows", "windows.bcrypt" },
    requires_native = {},
}
