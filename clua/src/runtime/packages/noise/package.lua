return {
    name        = "noise",
    version     = "1.0",
    description = "Procedural noise generators. Classic Perlin (2D + 3D), simplex (Ken Perlin 2001), value noise, and Voronoi / Worley cellular noise. Composable fractal layering helpers: fractal Brownian motion (fbm) and ridged multifractal. All generators are seeded via SplitMix64 producing a deterministic 256-entry permutation table per seed. Outputs are normalized to documented ranges -- Perlin/simplex roughly -1..1, value noise 0..1.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["noise"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
