-- Image decode + encode. Tries WIC first for full format coverage,
-- falls back to ffi.load("stb_image") if a stb_image.dll is on PATH,
-- and finally to a pure-Lua BMP + uncompressed-PNG decoder. Pure-Lua
-- encoders cover BMP and raw-store PNG (no zlib compression).
return {
    name        = "image",
    version     = "1.0",
    description = "Image decode + encode wrapper. Backends in order of preference: Windows Imaging Component (WIC, via windows.com), optional stb_image.dll if present, then a pure-Lua BMP / uncompressed-PNG decoder. Encoders: WIC for PNG/JPEG/BMP/GIF/TIFF, pure-Lua BMP and store-only PNG. Includes resize (nearest / bilinear) and crop helpers operating on the in-memory BGRA representation.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["image"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
