return {
    name        = "gis",
    version     = "1.0",
    description = "Geographic / GIS helpers. Great-circle distance via Haversine, geodesic via Vincenty, initial bearing, destination point, bounding box, geohash encode/decode/neighbors, point-in-polygon (ray cast), polygon area via the spherical-excess formula, line-segment intersection, and projection helpers (Mercator, Web-Mercator, equirectangular). All inputs use {lat, lon} tables.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["gis"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
