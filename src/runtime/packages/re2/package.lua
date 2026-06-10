return {
    name        = "re2",
    version     = "1.0",
    description = "RE2 (linear-time, no-backtracking) regex bindings via system re2.dll. Shares the surface shape of the pcre package (compile -> regex with :match / :find_all / :replace / :split). RE2 supports the Google RE2 syntax subset -- notably *no* backreferences and *no* lookaround, in exchange for guaranteed O(n) match time. Flags i (case-insensitive), m (multiline), s (dotall). DLL load is lazy: requiring the package never fails; compile() raises a clear error if re2.dll is absent.",
    license     = "MIT (bindings), BSD-3 (RE2 upstream)",
    main        = "init.lua",
    modules     = {
        ["re2"] = "init.lua",
    },
    requires        = {},
    requires_native = { { dll = "re2.dll", mode_default = "system" } },
}
