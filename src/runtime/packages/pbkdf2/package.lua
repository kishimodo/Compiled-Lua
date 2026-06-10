return {
    name        = "pbkdf2",
    version     = "1.0",
    description = "Password-based key derivation. PBKDF2 (RFC 2898) with HMAC-SHA1/256/384/512 (prefers BCryptDeriveKeyPBKDF2 fast path, falls back to pure-Lua HMAC loop). scrypt (RFC 7914) and Argon2id (RFC 9106) implemented in pure Lua over a self-contained BLAKE2b.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["pbkdf2"] = "init.lua",
    },
    requires        = { "hash", "hmac", "windows", "windows.bcrypt" },
    requires_native = {},
}
