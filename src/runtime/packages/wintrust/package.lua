return {
    name        = "wintrust",
    version     = "1.0",
    description = "Authenticode signature verification via WinTrust.dll. WinVerifyTrust with WINTRUST_ACTION_GENERIC_VERIFY_V2, signer / countersigner / certificate enumeration via wintrust + crypt32, embedded + catalog-based signature lookup (CryptCATAdminEnumCatalogFromHash), file-hash matching against the embedded SignerInfo content hash, and a lightweight is_signed shortcut.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["wintrust"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
