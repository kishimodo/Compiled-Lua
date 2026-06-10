return {
    name        = "rational",
    version     = "1.0",
    description = "Rational (Q) arithmetic. Numerator/denominator pair, kept canonical (gcd-reduced, denominator positive). Backed by bignum for unlimited range. Operator metatable for + - * / ^ < == unm. Decimal conversion (parse and emit with arbitrary precision).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["rational"] = "init.lua",
    },
    requires        = { "bignum" },
    requires_native = {},
}
