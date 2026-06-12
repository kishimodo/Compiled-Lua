return {
    name        = "string_extra",
    version     = "1.0",
    description = "String algorithm grab-bag: edit-distance (levenshtein / damerau-levenshtein / hamming), similarity (jaro / jaro-winkler / cosine over character n-grams), phonetic codes (soundex, metaphone, double metaphone), fuzzy subsequence-with-bonus scoring, longest-common-substring and longest-common-subsequence, simple whitespace tokenizer with optional stopword filtering, and an n-gram generator. Pure Lua, byte-oriented (callers feed pre-normalized UTF-8 or ASCII).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["string_extra"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
