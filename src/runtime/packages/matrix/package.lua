return {
    name        = "matrix",
    version     = "1.0",
    description = "General MxN matrices. Add, sub, multiply (matrix*matrix and matrix*vector), transpose, determinant (LU; explicit formulas for 2x2/3x3/4x4), inverse, identity, zeros/ones. LU and QR decomposition. Eigenvalues for 2x2/3x3 (closed-form). Graphics builders: rotation_x/y/z, scale, translation, perspective, lookat. Row/col extraction and submatrix slicing.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["matrix"] = "init.lua",
    },
    requires        = { "vector" },
    requires_native = {},
}
