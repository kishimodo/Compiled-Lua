return {
    name        = "cbor",
    version     = "1.0",
    description = "CBOR (RFC 8949) encoder + decoder. All major types 0-7 (unsigned/negative ints, byte/text strings, arrays, maps, tagged values, floats and simple values). Indefinite-length items, half/single/double floats, tag round-trip, streaming decode. Pure Lua.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cbor"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
