return {
    name        = "bignum",
    version     = "1.0",
    description = "Arbitrary-precision integers. 24-bit limbs so limb*limb stays exact in Lua doubles (mantissa is 53 bits; 24+24=48). Add/sub/mul/div/mod/pow with mod-exp (modpow) and mod-inverse (modinv), gcd/lcm/egcd, bitwise and/or/xor/not/shl/shr, popcount, isqrt, factorial, parse + tostring in any base 2-36. Karatsuba threshold for big multiplies. Miller-Rabin primality (is_prime). Random-in-range. Byte I/O with signed/unsigned + fixed length. Operator metatable so a + b works; bignum(x) callable for construction.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["bignum"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
