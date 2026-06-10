-- Media Foundation source / sink wrapper. Used by the audio package for
-- compressed-format decode; exposed separately for callers that need
-- video pipelines, format negotiation, or topology control.
return {
    name        = "mediafound",
    version     = "1.0",
    description = "Microsoft Media Foundation wrapper. Cdefs for IMFSourceReader / IMFSourceReaderEx / IMFMediaType / IMFSample / IMFMediaBuffer / IMFAttributes, plus the MFStartup / MFCreateSourceReaderFromURL / MFCreateMediaType helper exports. Supports audio + video decode and provides a high-level reader API that resolves the best stream for a given type and pulls native sample blobs.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["mediafound"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
