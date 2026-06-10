return {
    name        = "complex",
    version     = "1.0",
    description = "Complex numbers (a + bi) backed by Lua doubles. Full algebraic + transcendental surface: abs, arg, conj, exp, log, sqrt, pow, sin/cos/tan and asin/acos/atan, plus hyperbolics. Polar/cartesian construction. Operator metatable for + - * / ^.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["complex"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
