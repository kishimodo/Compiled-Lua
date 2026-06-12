return {
    name        = "creditcard",
    version     = "1.0",
    description = "Credit-card number validation + brand detection. Luhn (mod-10) checksum, IIN/BIN-prefix brand identification for Visa, Mastercard, American Express, Discover, JCB, Diners Club, UnionPay, Maestro, RuPay and others, length validation per brand, formatting and masking (PAN-aware so the BIN and last-4 stay visible), and generators that return one of the well-known industry test card numbers.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["creditcard"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
