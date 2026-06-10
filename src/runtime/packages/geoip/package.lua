return {
    name        = "geoip",
    version     = "1.0",
    description = "MaxMind GeoIP2 / GeoLite2 .mmdb binary-format reader. Pure-Lua parser for the MaxMind DB Format Specification v2: metadata sentinel scan, binary-tree node walk for IPv4 and IPv6 lookups, data-section decoder (pointer, utf8 string, double, bytes, uint16/32/64, int32, map, array, boolean, float). Returns the decoded record as a Lua table; works with GeoLite2-Country, GeoLite2-City, GeoLite2-ASN and any other MMDB schema.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["geoip"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
