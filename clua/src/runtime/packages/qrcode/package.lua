-- QR code generation in pure Lua. Supports numeric / alphanumeric / byte
-- modes, all 40 versions, the four ECC levels (L/M/Q/H), automatic mask
-- selection, and SVG + raster (BGRA) output. No external deps.
return {
    name        = "qrcode",
    version     = "1.0",
    description = "QR code matrix generator with Reed-Solomon error correction, ISO/IEC 18004. Modes: numeric, alphanumeric, byte. Versions 1..40, ECC L/M/Q/H, automatic mask selection. Renderers: SVG string, BGRA raster bytes (for the image package).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["qrcode"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
