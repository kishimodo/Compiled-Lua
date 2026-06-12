return {
    name        = "aes",
    version     = "1.0",
    description = "AES (128/192/256) via Windows CNG. Modes: ECB, CBC, CTR, GCM. PKCS#7 padding helpers. random_iv generator. GCM authenticated encryption with caller-supplied AAD and 12-byte nonces by default.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["aes"] = "init.lua",
    },
    requires        = { "windows", "windows.bcrypt" },
    requires_native = {},
}
