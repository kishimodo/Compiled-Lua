return {
    name        = "units",
    version     = "1.0",
    description = "Unit conversion with dimensional analysis. SI + imperial + others across length, mass, time, temperature, area, volume, speed, energy, force, pressure, power, frequency, current, voltage, resistance, data and angle. Quantity objects with arithmetic (addition for same-dimension values, multiplication / division producing composite dimensions). Parsing of '5.2 km' style strings, locale-aware formatting. 100+ unit names with aliases.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["units"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
