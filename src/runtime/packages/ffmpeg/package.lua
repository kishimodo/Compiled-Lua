-- Optional FFmpeg bindings. Loads avformat/avcodec/avutil/swscale via
-- ffi.load with version-stripping fallback. Requires the user to put
-- the matching DLLs (avformat-XX.dll etc.) somewhere on the PATH.
return {
    name        = "ffmpeg",
    version     = "1.0",
    description = "FFmpeg libav* bindings (avformat / avcodec / avutil / swscale). Open + demux media, decode video/audio streams, swscale-convert pixel formats. Optional: requires avformat-{58,59,60,61}.dll and matching avcodec / avutil / swscale builds on PATH. If the DLLs are absent the package returns a stub whose every call errors with a clear missing-dependency message rather than failing during require().",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["ffmpeg"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
