-- Windows Imaging Component wrapper. Talks IWICImagingFactory directly
-- via vtable cdefs. No external DLL needed beyond windowscodecs.dll
-- which ships with every Windows install.
return {
    name        = "wic",
    version     = "1.0",
    description = "Windows Imaging Component (WIC) wrapper. Exposes IWICImagingFactory, IWICBitmapDecoder, IWICBitmapFrameDecode, IWICFormatConverter and IWICBitmapEncoder via FFI vtables. Decodes PNG / JPEG / BMP / GIF / TIFF / WebP / ICO and re-encodes through the matching WIC codecs. Lower level than image -- prefer image for typical decode/encode tasks.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["wic"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
