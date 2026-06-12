-- Audio decode. WAV is pure Lua (covers every PCM variant). MP3/FLAC/
-- AAC/M4A go through Media Foundation's IMFSourceReader.
return {
    name        = "audio",
    version     = "1.0",
    description = "Audio file decode + WAV encode. WAV (RIFF) decoder is pure Lua and handles PCM 8/16/24/32-bit, IEEE float, mu-law, A-law, any channel count. MP3 / FLAC / AAC / M4A / WMA / OGG decode go through Windows Media Foundation (IMFSourceReader) via the windows.com vtable plumbing. Decoded samples are returned as native float32 by default; raw PCM is also available.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["audio"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
