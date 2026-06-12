return {
    name        = "phone",
    version     = "1.0",
    description = "E.164 phone-number parsing and validation. Identifies the country dialling code from a prefix table covering 200+ ITU country/region assignments, validates the national-number length against per-country min/max ranges, formats to E.164 / international / national / RFC 3966 (`tel:` URI), and classifies common number types (mobile/landline/voip/unknown) when a country-specific heuristic is available.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["phone"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
