return {
    name        = "mime",
    version     = "1.0",
    description = "MIME helpers: extension -> Content-Type lookup table covering common web, image, video, audio, font, archive and document formats; multipart/form-data and multipart/mixed parser + formatter (boundary-driven, header decoding included). Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["mime"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
