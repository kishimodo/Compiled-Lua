return {
    name        = "keychain",
    version     = "1.0",
    description = "Windows Credential Manager (Vault) wrapper. CredReadW / CredWriteW / CredDeleteW / CredEnumerateW for the generic, domain, and certificate credential types. Persistence scopes: session, local-machine, enterprise. Credentials are stored in the user's vault (DPAPI-encrypted under the hood) and accessible only to the calling user account.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["keychain"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
