-- CLua screenshot package manifest.
return {
    name        = "screenshot",
    version     = "0.1",
    description = "Screen / window / region capture to BGRA + PNG. Uses BitBlt + CreateCompatibleDC + GetDIBits for the capture and a hand-rolled pure-Lua PNG writer (CRC32 + zlib stored-block deflate) so output works on any reader without extra deps.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["screenshot"] = "init.lua",
    },
    requires        = { "windows", "display" },
    requires_native = {},
}
