return {
    name        = "dpapi",
    version     = "1.0",
    description = "Windows Data Protection API (DPAPI) wrapper. CryptProtectData / CryptUnprotectData with user or machine scope, optional secondary entropy (per-secret key material), prompt-flag control, and round-trip helpers for raw bytes and strings. NgcProtect / NgcUnprotect for the modern (Win10+) credential-vault path that ties protection to the user's PIN/biometric next-gen credential.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["dpapi"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
