return {
    name        = "currency",
    version     = "1.0",
    description = "Currency conversion and locale-aware formatting. ISO 4217 codes with name + symbol + decimal-places metadata for 60+ currencies. Static exchange-rate table (default seed shipped) with set_rates / set_rate_provider for live-rate hooks. Locale presets covering en-US, en-GB, de-DE, fr-FR, ja-JP, etc. Robust parser tolerating $, suffixed codes and grouping separators.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["currency"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
