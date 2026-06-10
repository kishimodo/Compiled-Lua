-- units -- Unit conversion + dimensional analysis.
--
-- Internally every unit is stored as { factor, offset, dim } where
--   factor : multiply by this to get SI base units
--   offset : applied AFTER factor (only non-zero for temperatures: degC, degF)
--   dim    : seven-vector { L, M, T, K, I, N, J } following SI
--
-- Public surface:
--   units.convert(value, from, to)        -> number
--   units.parse(text)                     -> value, unit_name
--   units.format(value, unit, opts?)      -> string
--   units.q(value, unit)                  -> quantity object
--   units.unit(name)                      -> unit table (or nil)
--   units.dimension_of(name)              -> dim vector
--   units.list(category?)                 -> array of unit names
--
-- Quantity object methods:
--   q:value()            raw numeric value in the unit it was constructed with
--   q:unit()             unit name
--   q:dimension()        dim vector
--   q:to(unit)           convert to another unit (returns new q)
--   q:si()               value reduced to SI base units
--   tostring(q)          "value unit"
--   Arithmetic: + - (same dimension), * / (composite), unary -, == (compares SI value)

local M = {}

-- ===== Dimension vector ================================================
-- Order: length, mass, time, temperature, current, amount, luminous

local function newdim(L, MA, T, K, I, N, J)
    return { L or 0, MA or 0, T or 0, K or 0, I or 0, N or 0, J or 0 }
end

local function dim_eq(a, b)
    for i = 1, 7 do if a[i] ~= b[i] then return false end end
    return true
end

local function dim_add(a, b)
    return { a[1]+b[1], a[2]+b[2], a[3]+b[3], a[4]+b[4],
             a[5]+b[5], a[6]+b[6], a[7]+b[7] }
end

local function dim_sub(a, b)
    return { a[1]-b[1], a[2]-b[2], a[3]-b[3], a[4]-b[4],
             a[5]-b[5], a[6]-b[6], a[7]-b[7] }
end

local function dim_scale(a, k)
    return { a[1]*k, a[2]*k, a[3]*k, a[4]*k, a[5]*k, a[6]*k, a[7]*k }
end

local function dim_zero(a)
    for i = 1, 7 do if a[i] ~= 0 then return false end end
    return true
end

-- ===== Base dimensions =================================================

local D = {
    DIMENSIONLESS = newdim(),
    LENGTH        = newdim(1),
    MASS          = newdim(0,1),
    TIME          = newdim(0,0,1),
    TEMPERATURE   = newdim(0,0,0,1),
    CURRENT       = newdim(0,0,0,0,1),
    AMOUNT        = newdim(0,0,0,0,0,1),
    LUMINOUS      = newdim(0,0,0,0,0,0,1),

    AREA          = newdim(2),
    VOLUME        = newdim(3),
    SPEED         = newdim(1,0,-1),
    ACCEL         = newdim(1,0,-2),
    FORCE         = newdim(1,1,-2),
    ENERGY        = newdim(2,1,-2),
    POWER         = newdim(2,1,-3),
    PRESSURE      = newdim(-1,1,-2),
    FREQUENCY     = newdim(0,0,-1),
    VOLTAGE       = newdim(2,1,-3,0,-1),
    RESISTANCE    = newdim(2,1,-3,0,-2),
    DATA          = newdim(),  -- treated as dimensionless count of bits
    ANGLE         = newdim(),  -- radians = dimensionless (SI convention)
}

-- ===== Unit table ======================================================

local UNITS = {}
local CAT   = {}     -- category -> list of unit names

local function reg(names, factor, offset, dim, category)
    if type(names) == "string" then names = { names } end
    local first = names[1]
    local u = { factor = factor, offset = offset or 0, dim = dim,
                name = first, category = category }
    for _, n in ipairs(names) do UNITS[n] = u end
    CAT[category] = CAT[category] or {}
    CAT[category][#CAT[category] + 1] = first
end

-- ----- length (SI metre) -----
reg({"m","meter","meters","metre","metres"},  1,           0, D.LENGTH, "length")
reg({"km","kilometer","kilometers","kilometre","kilometres"}, 1e3, 0, D.LENGTH, "length")
reg({"cm","centimeter","centimeters","centimetre","centimetres"}, 1e-2, 0, D.LENGTH, "length")
reg({"mm","millimeter","millimeters","millimetre","millimetres"}, 1e-3, 0, D.LENGTH, "length")
reg({"um","micrometer","micrometers","micron","microns"}, 1e-6, 0, D.LENGTH, "length")
reg({"nm","nanometer","nanometers","nanometre"},          1e-9, 0, D.LENGTH, "length")
reg({"pm","picometer","picometers"},                      1e-12,0, D.LENGTH, "length")
reg({"in","inch","inches"},                               0.0254,0, D.LENGTH, "length")
reg({"ft","foot","feet"},                                 0.3048,0, D.LENGTH, "length")
reg({"yd","yard","yards"},                                0.9144,0, D.LENGTH, "length")
reg({"mi","mile","miles"},                                1609.344,0, D.LENGTH, "length")
reg({"nmi","nautical_mile","nautical_miles"},             1852,0, D.LENGTH, "length")
reg({"au","astronomical_unit"},                           1.495978707e11, 0, D.LENGTH, "length")
reg({"ly","lightyear","light_year"},                      9.4607304725808e15, 0, D.LENGTH, "length")
reg({"pc","parsec","parsecs"},                            3.0856775814913673e16, 0, D.LENGTH, "length")
reg({"angstrom","angstroms"},                             1e-10, 0, D.LENGTH, "length")
reg({"fathom","fathoms"},                                 1.8288, 0, D.LENGTH, "length")
reg({"furlong","furlongs"},                               201.168, 0, D.LENGTH, "length")

-- ----- mass (SI kg) -----
reg({"kg","kilogram","kilograms"},  1,        0, D.MASS, "mass")
reg({"g","gram","grams"},           1e-3,     0, D.MASS, "mass")
reg({"mg","milligram","milligrams"},1e-6,     0, D.MASS, "mass")
reg({"ug","microgram","micrograms"},1e-9,     0, D.MASS, "mass")
reg({"t","tonne","tonnes","metric_ton"}, 1e3, 0, D.MASS, "mass")
reg({"lb","lbs","pound","pounds"},  0.45359237, 0, D.MASS, "mass")
reg({"oz","ounce","ounces"},        0.028349523125, 0, D.MASS, "mass")
reg({"st","stone","stones"},        6.35029318, 0, D.MASS, "mass")
reg({"ton_us","short_ton"},         907.18474, 0, D.MASS, "mass")
reg({"ton_uk","long_ton"},          1016.0469088, 0, D.MASS, "mass")
reg({"slug","slugs"},               14.59390294, 0, D.MASS, "mass")
reg({"carat","carats","ct"},        2e-4, 0, D.MASS, "mass")
reg({"grain","grains","gr"},        6.479891e-5, 0, D.MASS, "mass")

-- ----- time (SI second) -----
reg({"s","sec","secs","second","seconds"}, 1,       0, D.TIME, "time")
reg({"ms","millisecond","milliseconds"},   1e-3,    0, D.TIME, "time")
reg({"us","microsecond","microseconds"},   1e-6,    0, D.TIME, "time")
reg({"ns","nanosecond","nanoseconds"},     1e-9,    0, D.TIME, "time")
reg({"ps","picosecond","picoseconds"},     1e-12,   0, D.TIME, "time")
reg({"min","mins","minute","minutes"},     60,      0, D.TIME, "time")
reg({"h","hr","hrs","hour","hours"},       3600,    0, D.TIME, "time")
reg({"d","day","days"},                    86400,   0, D.TIME, "time")
reg({"wk","week","weeks"},                 604800,  0, D.TIME, "time")
reg({"mo","month","months"},               2629800, 0, D.TIME, "time")  -- average gregorian month
reg({"yr","year","years","y"},             31557600, 0, D.TIME, "time") -- julian year

-- ----- temperature -----
-- For temperature we store both factor and offset such that
--   si_K = value * factor + offset
-- The 'convert' path handles this specially (no general composition).
reg({"K","kelvin","kelvins"},               1, 0,      D.TEMPERATURE, "temperature")
reg({"degC","celsius","C","centigrade"},    1, 273.15, D.TEMPERATURE, "temperature")
reg({"degF","fahrenheit","F"},              5/9, 459.67 * 5/9, D.TEMPERATURE, "temperature")
reg({"degR","rankine","R"},                 5/9, 0,    D.TEMPERATURE, "temperature")

-- ----- area (m^2) -----
reg({"m2","m^2","sqm","square_meter","square_meters"}, 1, 0, D.AREA, "area")
reg({"cm2","sqcm","square_centimeter"},      1e-4, 0, D.AREA, "area")
reg({"km2","sqkm","square_kilometer"},       1e6,  0, D.AREA, "area")
reg({"mm2","sqmm","square_millimeter"},      1e-6, 0, D.AREA, "area")
reg({"in2","sqin","square_inch","square_inches"}, 0.0254^2, 0, D.AREA, "area")
reg({"ft2","sqft","square_foot","square_feet"},   0.3048^2, 0, D.AREA, "area")
reg({"yd2","sqyd","square_yard"},                 0.9144^2, 0, D.AREA, "area")
reg({"mi2","sqmi","square_mile"},                 1609.344^2, 0, D.AREA, "area")
reg({"ha","hectare","hectares"},                  1e4,    0, D.AREA, "area")
reg({"acre","acres"},                             4046.8564224, 0, D.AREA, "area")
reg({"are","ares"},                               100, 0, D.AREA, "area")

-- ----- volume (m^3) -----
reg({"m3","m^3","cubic_meter","cubic_meters"},   1,   0, D.VOLUME, "volume")
reg({"cm3","cubic_centimeter","cc"},             1e-6, 0, D.VOLUME, "volume")
reg({"mm3","cubic_millimeter"},                  1e-9, 0, D.VOLUME, "volume")
reg({"L","l","liter","liters","litre","litres"}, 1e-3, 0, D.VOLUME, "volume")
reg({"mL","ml","milliliter","milliliters"},      1e-6, 0, D.VOLUME, "volume")
reg({"dL","dl","deciliter","deciliters"},        1e-4, 0, D.VOLUME, "volume")
reg({"gal","gallon","gallons","gal_us"},         3.785411784e-3, 0, D.VOLUME, "volume")
reg({"gal_uk","imperial_gallon"},                4.54609e-3,     0, D.VOLUME, "volume")
reg({"qt","quart","quarts"},                     9.46352946e-4,  0, D.VOLUME, "volume")
reg({"pt","pint","pints"},                       4.73176473e-4,  0, D.VOLUME, "volume")
reg({"cup","cups"},                              2.365882365e-4, 0, D.VOLUME, "volume")
reg({"floz","fluid_ounce","fluid_ounces"},       2.95735295625e-5,0,D.VOLUME, "volume")
reg({"tbsp","tablespoon","tablespoons"},         1.4786764765625e-5, 0, D.VOLUME, "volume")
reg({"tsp","teaspoon","teaspoons"},              4.92892159375e-6, 0, D.VOLUME, "volume")
reg({"bbl","barrel","barrels"},                  0.158987294928, 0, D.VOLUME, "volume")
reg({"in3","cubic_inch"},                        0.0254^3, 0, D.VOLUME, "volume")
reg({"ft3","cubic_foot","cubic_feet"},           0.3048^3, 0, D.VOLUME, "volume")
reg({"yd3","cubic_yard"},                        0.9144^3, 0, D.VOLUME, "volume")

-- ----- speed (m/s) -----
reg({"m_s","m/s","mps","meter_per_second","meters_per_second"}, 1, 0, D.SPEED, "speed")
reg({"km_h","km/h","kph","kilometer_per_hour"},  1000/3600, 0, D.SPEED, "speed")
reg({"mph","mile_per_hour","miles_per_hour"},    1609.344/3600, 0, D.SPEED, "speed")
reg({"knot","knots","kn","kt"},                  1852/3600, 0, D.SPEED, "speed")
reg({"ft_s","ft/s","foot_per_second"},           0.3048, 0, D.SPEED, "speed")
reg({"mach"},                                    340.29, 0, D.SPEED, "speed")
reg({"c_light","speed_of_light"},                299792458, 0, D.SPEED, "speed")

-- ----- force (N) -----
reg({"N","newton","newtons"},          1, 0, D.FORCE, "force")
reg({"kN","kilonewton"},               1e3, 0, D.FORCE, "force")
reg({"mN","millinewton"},              1e-3, 0, D.FORCE, "force")
reg({"dyn","dyne","dynes"},            1e-5, 0, D.FORCE, "force")
reg({"lbf","pound_force","pounds_force"}, 4.4482216152605, 0, D.FORCE, "force")
reg({"kgf","kilogram_force"},          9.80665, 0, D.FORCE, "force")
reg({"ozf","ounce_force"},             0.2780138509537812, 0, D.FORCE, "force")
reg({"poundal"},                       0.138254954376, 0, D.FORCE, "force")

-- ----- energy (J) -----
reg({"J","joule","joules"},            1, 0, D.ENERGY, "energy")
reg({"kJ","kilojoule","kilojoules"},   1e3, 0, D.ENERGY, "energy")
reg({"MJ","megajoule"},                1e6, 0, D.ENERGY, "energy")
reg({"mJ","millijoule"},               1e-3, 0, D.ENERGY, "energy")
reg({"cal","calorie","calories"},      4.184, 0, D.ENERGY, "energy")
reg({"kcal","kilocalorie","kilocalories","Cal"}, 4184, 0, D.ENERGY, "energy")
reg({"Wh","watt_hour","watt_hours"},   3600, 0, D.ENERGY, "energy")
reg({"kWh","kilowatt_hour","kilowatt_hours"}, 3.6e6, 0, D.ENERGY, "energy")
reg({"MWh","megawatt_hour"},           3.6e9, 0, D.ENERGY, "energy")
reg({"eV","electronvolt","electronvolts"}, 1.602176634e-19, 0, D.ENERGY, "energy")
reg({"keV","kiloelectronvolt"},        1.602176634e-16, 0, D.ENERGY, "energy")
reg({"MeV","megaelectronvolt"},        1.602176634e-13, 0, D.ENERGY, "energy")
reg({"erg","ergs"},                    1e-7, 0, D.ENERGY, "energy")
reg({"BTU","btu","british_thermal_unit"}, 1055.05585262, 0, D.ENERGY, "energy")
reg({"ftlbf","foot_pound","foot_pounds"}, 1.3558179483314004, 0, D.ENERGY, "energy")

-- ----- power (W) -----
reg({"W","watt","watts"},              1, 0, D.POWER, "power")
reg({"kW","kilowatt","kilowatts"},     1e3, 0, D.POWER, "power")
reg({"MW","megawatt","megawatts"},     1e6, 0, D.POWER, "power")
reg({"GW","gigawatt","gigawatts"},     1e9, 0, D.POWER, "power")
reg({"mW","milliwatt"},                1e-3, 0, D.POWER, "power")
reg({"hp","horsepower"},               745.6998715822702, 0, D.POWER, "power")
reg({"hp_metric","ps"},                735.49875, 0, D.POWER, "power")
reg({"BTU_h","btu_per_hour"},          0.29307107017222, 0, D.POWER, "power")

-- ----- pressure (Pa) -----
reg({"Pa","pascal","pascals"},         1, 0, D.PRESSURE, "pressure")
reg({"kPa","kilopascal"},              1e3, 0, D.PRESSURE, "pressure")
reg({"MPa","megapascal"},              1e6, 0, D.PRESSURE, "pressure")
reg({"hPa","hectopascal"},             1e2, 0, D.PRESSURE, "pressure")
reg({"bar","bars"},                    1e5, 0, D.PRESSURE, "pressure")
reg({"mbar","millibar"},               1e2, 0, D.PRESSURE, "pressure")
reg({"atm","atmosphere"},              101325, 0, D.PRESSURE, "pressure")
reg({"psi","pound_per_square_inch"},   6894.757293168361, 0, D.PRESSURE, "pressure")
reg({"torr","mmHg"},                   133.322387415, 0, D.PRESSURE, "pressure")
reg({"inHg","inch_of_mercury"},        3386.388640341, 0, D.PRESSURE, "pressure")

-- ----- frequency (Hz) -----
reg({"Hz","hertz"},                    1, 0, D.FREQUENCY, "frequency")
reg({"kHz","kilohertz"},               1e3, 0, D.FREQUENCY, "frequency")
reg({"MHz","megahertz"},               1e6, 0, D.FREQUENCY, "frequency")
reg({"GHz","gigahertz"},               1e9, 0, D.FREQUENCY, "frequency")
reg({"THz","terahertz"},               1e12, 0, D.FREQUENCY, "frequency")
reg({"rpm"},                           1/60, 0, D.FREQUENCY, "frequency")

-- ----- current (A) -----
reg({"A","amp","amps","ampere","amperes"}, 1, 0, D.CURRENT, "current")
reg({"mA","milliampere","milliamperes"},   1e-3, 0, D.CURRENT, "current")
reg({"uA","microampere"},                  1e-6, 0, D.CURRENT, "current")
reg({"kA","kiloampere"},                   1e3,  0, D.CURRENT, "current")

-- ----- voltage (V) -----
reg({"V","volt","volts"},              1, 0, D.VOLTAGE, "voltage")
reg({"mV","millivolt"},                1e-3, 0, D.VOLTAGE, "voltage")
reg({"kV","kilovolt"},                 1e3,  0, D.VOLTAGE, "voltage")
reg({"MV","megavolt"},                 1e6,  0, D.VOLTAGE, "voltage")

-- ----- resistance (ohm) -----
reg({"ohm","ohms","Ohm","Ω"},          1, 0, D.RESISTANCE, "resistance")
reg({"kohm","kilohm"},                 1e3, 0, D.RESISTANCE, "resistance")
reg({"Mohm","megohm"},                 1e6, 0, D.RESISTANCE, "resistance")
reg({"mohm","milliohm"},               1e-3, 0, D.RESISTANCE, "resistance")

-- ----- data (bit / byte). All dimensionless. Factor is bits. -----
reg({"bit","bits","b"},                1, 0, D.DATA, "data")
reg({"byte","bytes","B"},              8, 0, D.DATA, "data")
reg({"kB","kilobyte","kilobytes"},     8e3, 0, D.DATA, "data")
reg({"MB","megabyte","megabytes"},     8e6, 0, D.DATA, "data")
reg({"GB","gigabyte","gigabytes"},     8e9, 0, D.DATA, "data")
reg({"TB","terabyte","terabytes"},     8e12, 0, D.DATA, "data")
reg({"PB","petabyte","petabytes"},     8e15, 0, D.DATA, "data")
reg({"KiB","kibibyte","kibibytes"},    8 * 1024, 0, D.DATA, "data")
reg({"MiB","mebibyte","mebibytes"},    8 * 1024^2, 0, D.DATA, "data")
reg({"GiB","gibibyte","gibibytes"},    8 * 1024^3, 0, D.DATA, "data")
reg({"TiB","tebibyte","tebibytes"},    8 * 1024^4, 0, D.DATA, "data")
reg({"kbit","kilobit"},                1e3, 0, D.DATA, "data")
reg({"Mbit","megabit"},                1e6, 0, D.DATA, "data")
reg({"Gbit","gigabit"},                1e9, 0, D.DATA, "data")

-- ----- angle -----
reg({"rad","radian","radians"},        1, 0, D.ANGLE, "angle")
reg({"deg","degree","degrees","°"},    math.pi / 180, 0, D.ANGLE, "angle")
reg({"grad","gradian","gradians","gon"}, math.pi / 200, 0, D.ANGLE, "angle")
reg({"arcmin","arcminute"},            math.pi / (180*60), 0, D.ANGLE, "angle")
reg({"arcsec","arcsecond"},            math.pi / (180*3600), 0, D.ANGLE, "angle")
reg({"turn","turns","rev","revolution"}, 2 * math.pi, 0, D.ANGLE, "angle")

-- ===== Lookup ==========================================================

function M.unit(name)
    return UNITS[name]
end

function M.dimension_of(name)
    local u = UNITS[name]
    return u and u.dim or nil
end

function M.list(category)
    if category then
        local r = {}
        for i, n in ipairs(CAT[category] or {}) do r[i] = n end
        return r
    end
    local r = {}
    for cat, list in pairs(CAT) do
        for _, n in ipairs(list) do r[#r + 1] = n end
    end
    table.sort(r)
    return r
end

-- ===== Convert =========================================================

function M.convert(value, from, to)
    local fu = UNITS[from]
    local tu = UNITS[to]
    if not fu then error("units: unknown unit '" .. tostring(from) .. "'") end
    if not tu then error("units: unknown unit '" .. tostring(to)   .. "'") end
    if not dim_eq(fu.dim, tu.dim) then
        error("units: incompatible dimensions: " .. from .. " vs " .. to)
    end
    -- Apply: value -> SI: si = value * factor + offset
    --        SI -> target: target = (si - target.offset) / target.factor
    local si = value * fu.factor + fu.offset
    return (si - tu.offset) / tu.factor
end

-- ===== Parse ==========================================================

function M.parse(text)
    if type(text) ~= "string" then
        error("units.parse: expected string, got " .. type(text))
    end
    -- Accept: "<number> <unit>"  or "<number><unit>" (no space), or a bare
    -- dimensionless number. Number may be integer, decimal, sign, scientific.
    --
    -- Try the UNITLESS form FIRST. The value+unit pattern ends in a mandatory
    -- unit group [%S]+, and for a bare number like "100" the greedy number
    -- group backtracks to hand its trailing digit(s) to that group -- so it
    -- "succeeded" with value=10, unit="0". Matching the unitless form first
    -- (and requiring the unit to start with a non-digit, non-sign character)
    -- avoids stealing digits.
    local num_str = text:match("^%s*([%-%+]?[%d%.]+[eE]?[%-%+]?%d*)%s*$")
    if num_str then
        local n = tonumber(num_str)
        if n ~= nil then return n, nil end
    end
    -- Value + unit. The unit group is anchored to start with a letter or '%'
    -- so it cannot absorb a trailing digit of the number.
    local unit_str
    num_str, unit_str = text:match("^%s*([%-%+]?[%d%.]+[eE]?[%-%+]?%d*)%s*([%a%%][%S]*)%s*$")
    if not num_str then
        error("units.parse: cannot parse '" .. text .. "'")
    end
    local n = tonumber(num_str)
    if n == nil then
        error("units.parse: bad number in '" .. text .. "'")
    end
    return n, unit_str
end

-- ===== Format ==========================================================

local function default_decimals(value)
    if value == 0 then return 0 end
    local absv = math.abs(value)
    if absv >= 1000 then return 0 end
    if absv >= 100 then  return 1 end
    if absv >= 10 then   return 2 end
    if absv >= 1 then    return 3 end
    return 4
end

local function format_number(v, decimals, decimal_sep, thousand_sep)
    decimal_sep  = decimal_sep  or "."
    thousand_sep = thousand_sep or ""
    local s = string.format("%." .. decimals .. "f", v)
    local sign = ""
    if s:sub(1,1) == "-" then sign = "-"; s = s:sub(2) end
    local int_part, frac_part = s:match("^(%d+)%.?(%d*)$")
    if not int_part then return sign .. s end
    -- Add thousand separators.
    if thousand_sep ~= "" then
        local rev = int_part:reverse()
        local grouped = rev:gsub("(%d%d%d)", "%1" .. thousand_sep)
        grouped = grouped:reverse()
        if grouped:sub(1,1) == thousand_sep then grouped = grouped:sub(2) end
        int_part = grouped
    end
    if frac_part and #frac_part > 0 then
        return sign .. int_part .. decimal_sep .. frac_part
    end
    return sign .. int_part
end

function M.format(value, unit, opts)
    opts = opts or {}
    local decimals = opts.decimals or default_decimals(value)
    local sep_dec  = opts.decimal_sep  or "."
    local sep_thou = opts.thousand_sep or ""
    local sym      = opts.symbol or unit
    local sp       = opts.space ~= false and " " or ""
    if not sym then return format_number(value, decimals, sep_dec, sep_thou) end
    return format_number(value, decimals, sep_dec, sep_thou) .. sp .. sym
end

-- ===== Quantity object =================================================

local qmt = {}
qmt.__index = qmt

local function dim_label(dim)
    if dim_zero(dim) then return "(dimensionless)" end
    local labels = {"L","M","T","K","I","N","J"}
    local parts = {}
    for i = 1, 7 do
        if dim[i] ~= 0 then
            if dim[i] == 1 then parts[#parts + 1] = labels[i]
            else parts[#parts + 1] = labels[i] .. "^" .. tostring(dim[i]) end
        end
    end
    return table.concat(parts, "*")
end

local function make_q(value, unit_name, dim, factor, offset)
    -- unit_name may be nil for composite (multiplied/divided) quantities; we
    -- then store value in SI and dim as the resulting dimension vector.
    return setmetatable({
        _v     = value,
        _u     = unit_name,
        _d     = dim,
        _f     = factor,
        _o     = offset or 0,
    }, qmt)
end

function M.q(value, unit_name)
    if unit_name == nil then
        return make_q(value, nil, D.DIMENSIONLESS, 1, 0)
    end
    local u = UNITS[unit_name]
    if not u then error("units.q: unknown unit '" .. unit_name .. "'") end
    return make_q(value, unit_name, u.dim, u.factor, u.offset)
end

function qmt:value()     return self._v end
function qmt:unit()      return self._u end
function qmt:dimension() return self._d end

function qmt:si()
    -- Value reduced to SI base unit(s).
    return self._v * self._f + self._o
end

function qmt:to(unit_name)
    local target = UNITS[unit_name]
    if not target then error("units q:to: unknown unit '" .. unit_name .. "'") end
    if not dim_eq(self._d, target.dim) then
        error("units q:to: incompatible dimensions: " .. dim_label(self._d) ..
              " -> " .. dim_label(target.dim))
    end
    local si = self:si()
    local v  = (si - target.offset) / target.factor
    return make_q(v, unit_name, target.dim, target.factor, target.offset)
end

function qmt.__add(a, b)
    if not dim_eq(a._d, b._d) then
        error("units +: incompatible dimensions")
    end
    -- Convert b to a's unit before adding so user keeps a's unit label.
    local b_in_a = (b:si() - a._o) / a._f
    return make_q(a._v + b_in_a, a._u, a._d, a._f, a._o)
end

function qmt.__sub(a, b)
    if not dim_eq(a._d, b._d) then
        error("units -: incompatible dimensions")
    end
    local b_in_a = (b:si() - a._o) / a._f
    return make_q(a._v - b_in_a, a._u, a._d, a._f, a._o)
end

function qmt.__mul(a, b)
    -- Allow q * number, number * q, q * q.
    if type(a) == "number" then
        return make_q(a * b._v, b._u, b._d, b._f, b._o)
    end
    if type(b) == "number" then
        return make_q(a._v * b, a._u, a._d, a._f, a._o)
    end
    -- q * q: multiply in SI, result is dimensionally combined; we lose the
    -- named-unit shortcut and store as composite (unit name = nil, factor=1).
    local si = a:si() * b:si()
    return make_q(si, nil, dim_add(a._d, b._d), 1, 0)
end

function qmt.__div(a, b)
    if type(b) == "number" then
        return make_q(a._v / b, a._u, a._d, a._f, a._o)
    end
    if type(a) == "number" then
        local si = a / b:si()
        return make_q(si, nil, dim_scale(b._d, -1), 1, 0)
    end
    local si = a:si() / b:si()
    return make_q(si, nil, dim_sub(a._d, b._d), 1, 0)
end

function qmt.__unm(a)
    return make_q(-a._v, a._u, a._d, a._f, a._o)
end

function qmt.__eq(a, b)
    if not dim_eq(a._d, b._d) then return false end
    return math.abs(a:si() - b:si()) < 1e-12 * math.max(1, math.abs(a:si()))
end

function qmt.__lt(a, b)
    if not dim_eq(a._d, b._d) then
        error("units <: incompatible dimensions")
    end
    return a:si() < b:si()
end

function qmt.__le(a, b)
    if not dim_eq(a._d, b._d) then
        error("units <=: incompatible dimensions")
    end
    return a:si() <= b:si()
end

function qmt.__tostring(q)
    local label = q._u or dim_label(q._d)
    return tostring(q._v) .. " " .. label
end

-- Expose for introspection.
M.dimensions = D
M._units_table = UNITS

return M
