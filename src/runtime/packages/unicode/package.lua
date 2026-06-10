return {
    name        = "unicode",
    version     = "1.0",
    description = "Unicode normalization (NFC, NFD, NFKC, NFKD), character properties (general category, scripts, letter / digit / whitespace predicates), casing (upper / lower / title) and UTF-8 iteration. Backed by the Win32 NormalizeString / GetStringTypeW / LCMapStringEx APIs shipped on every Windows install. codepoints() / codepoint_at() / length() are pure-Lua UTF-8 decoders so callers can walk strings without crossing the FFI boundary in the hot path.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["unicode"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
