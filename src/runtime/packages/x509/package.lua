return {
    name        = "x509",
    version     = "1.0",
    description = "X.509 v3 certificate parser plus Windows chain validation. Pure-Lua ASN.1 DER decoder extracts subject/issuer DNs, validity, signature-algorithm OID, public-key info (RSA modulus/exponent or EC point + curve), v3 extensions (SAN, key usage, EKU, basic constraints, AKI/SKI). Crypt32 backend exposes verify_chain (uses the OS trust store, accepts caller-supplied intermediates) and system_store('ROOT'|'CA'|'MY'|...) enumeration. parse() auto-detects PEM vs DER. to_pem() re-emits a parsed cert.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["x509"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
