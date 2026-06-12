return {
    name        = "iban",
    version     = "1.0",
    description = "IBAN (International Bank Account Number) validation, parsing and formatting. ISO 13616 country-specific length and BBAN structure checks for 80+ countries, the mod-97 == 1 check-digit algorithm (rearrange-letters-to-digits-and-reduce), bank/branch/account extraction per country pattern, and pretty-printing in the canonical 4-character groups.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["iban"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
