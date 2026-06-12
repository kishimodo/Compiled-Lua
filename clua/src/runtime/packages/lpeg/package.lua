return {
    name        = "lpeg",
    version     = "1.0",
    description = "LPeg-compatible parsing-expression-grammar surface. Soft-loads Roberto Ierusalimschy's native lpeg54.dll / lpeg.dll if available, otherwise falls back to a pure-Lua implementation covering the same essentials: P (literal/pattern), S (set), R (range), V (rule), B (look-behind), C (capture), Cs (substitution capture), Ct (table capture), Cg (group capture), Cc (constant), Cmt (match-time capture), plus the operator overloads * (sequence), + (ordered choice), ^ (repetition: n>=0 = at-least, -n = at-most), - (difference / negation), # (and-predicate). match(pattern, subject, init?) drives the engine. The wrapper does NOT inject lpeg into the global namespace; require it explicitly.",
    license     = "MIT (glue), MIT (lpeg upstream)",
    main        = "init.lua",
    modules     = {
        ["lpeg"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "lpeg54.dll", mode_default = "embed", env_var = "LUAVM_LPEG_DLL", optional = true },
    },
}
