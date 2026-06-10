return {
    name        = "vector",
    version     = "1.0",
    description = "N-dimensional vectors with optimized 2D/3D/4D fast paths. Supports xyzw component access plus indexed access; arithmetic via metatable; dot, cross (3D), length, normalize, lerp, and angle_between. Module-level helpers mirror the methods.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["vector"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
