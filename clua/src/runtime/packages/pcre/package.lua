return {
    name        = "pcre",
    version     = "1.0",
    description = "PCRE2 (8-bit) regex bindings via pcre2-8.dll. Real Perl-compatible regex (a superset of Lua patterns) with named + numbered captures, lazy quantifiers, look-around, back-references and Unicode (PCRE2_UTF | PCRE2_UCP). Surface: compile(pattern, flags?) -> regex with :match / :find / :gmatch / :gsub / :split / :test, plus module-level convenience wrappers that compile + run in one call. Flags string letters: i (caseless), m (multiline), s (dotall), x (extended), U (ungreedy). The DLL is loaded lazily via pcall(ffi.load) so the module always loads cleanly; calling compile() when pcre2-8.dll is absent raises a clear error.",
    license     = "MIT (bindings), BSD (PCRE2 upstream)",
    main        = "init.lua",
    modules     = {
        ["pcre"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "pcre2-8.dll", mode_default = "embed", env_var = "CLUA_PCRE2_DLL" },
    },
}
