return {
    name        = "bezier",
    version     = "1.0",
    description = "Quadratic and cubic Bezier curve math. Evaluation via De Casteljau, derivatives, arc-length by adaptive numeric integration, t-splitting, closest-point projection via Newton refinement, adaptive flattening to a polyline, axis-aligned bounding box from derivative roots, SVG path emission, and least-squares fitting of cubic curves to a sequence of points.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["bezier"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
