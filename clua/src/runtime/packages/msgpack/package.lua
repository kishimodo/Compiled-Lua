return {
    name        = "msgpack",
    version     = "1.0",
    description = "MessagePack encoder + decoder. Full spec coverage: nil, bool, positive/negative fixint, uint8/16/32/64, int8/16/32/64, float32/64, fixstr/str8/16/32, bin8/16/32, fixarray/array16/32, fixmap/map16/32, fixext1/2/4/8/16 and ext8/16/32. Streaming-friendly unpack(pos). Custom ext-type registration. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["msgpack"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
