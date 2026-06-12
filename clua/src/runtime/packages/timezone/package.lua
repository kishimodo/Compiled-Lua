return {
    name        = "timezone",
    version     = "2.0",
    description = "IANA-style timezone object with DST-aware offset/name/is_dst lookup. get(name) -> tz object; tz:offset_at(t), tz:is_dst(t), tz:name_at(t). list() enumerates the bundled zones (UTC, common America/Europe/Asia/Australia + a few Africa/Pacific). local_zone() builds a tz backed by Win32 GetDynamicTimeZoneInformation + GetTimeZoneInformationForYear so DST is honored by the OS rules. to_zone(t, name) / from_zone(t, name) convert datetime objects across zones. Numeric \"UTC+N\" / \"UTC-N\" forms are also accepted by get().",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["timezone"] = "init.lua",
    },
    requires        = { "time" },
    requires_native = {},
}
