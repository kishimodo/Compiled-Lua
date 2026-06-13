return {
    name        = "harfbuzz",
    version     = "1.0",
    description = "HarfBuzz text shaping bindings via harfbuzz.dll. Companion to cairo for correct OpenType / Unicode-aware glyph layout (ligatures, kerning, complex scripts, RTL, contextual substitutions). Surface: face(path_or_bytes) -> face; face:font(size?) -> font; font:shape(text, opts?) returns a list of {glyph_id, cluster, x_offset, y_offset, x_advance, y_advance, codepoint}. opts: { script='latn', language='en', direction='ltr'|'rtl'|'ttb'|'btt', features={'liga','kern','-liga',...} }. Helpers: language(code), script(tag), version(). Loads harfbuzz.dll lazily.",
    license     = "MIT (bindings), MIT-equivalent (HarfBuzz upstream)",
    main        = "init.lua",
    modules     = {
        ["harfbuzz"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "harfbuzz.dll", mode_default = "embed", env_var = "CLUA_HARFBUZZ_DLL" },
    },
}
