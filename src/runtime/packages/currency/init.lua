-- currency -- ISO 4217 currency table, conversion, locale-aware formatting.
--
-- All rates are stored as "units of <code> per 1 unit of base", where the
-- base defaults to USD. Callers can swap the base with set_rates({base, ...})
-- or wire a live source via set_rate_provider(fn).
--
-- Public surface:
--   currency.format(amount, code, opts?)    -> string
--   currency.parse(text)                    -> { amount, currency }
--   currency.convert(amount, from, to, rate?) -> number
--   currency.set_rates(rate_table)
--   currency.set_rate_provider(fn)
--   currency.rate(from, to)                 -> number
--   currency.currencies()                   -> array of {code, name, symbol, decimals}
--   currency.is_valid(code)                 -> boolean
--   currency.locale(name)                   -> locale table (or nil)

local M = {}

-- ===== Currency table (ISO 4217) ======================================
-- Each row: { name, symbol, decimal_places }

local CUR = {
    USD = { "US Dollar",            "$",      2 },
    EUR = { "Euro",                 "€",      2 },
    GBP = { "Pound Sterling",       "£",      2 },
    JPY = { "Japanese Yen",         "¥",      0 },
    CNY = { "Chinese Yuan",         "¥",      2 },
    HKD = { "Hong Kong Dollar",     "HK$",    2 },
    SGD = { "Singapore Dollar",     "S$",     2 },
    CHF = { "Swiss Franc",          "CHF",    2 },
    CAD = { "Canadian Dollar",      "CA$",    2 },
    AUD = { "Australian Dollar",    "A$",     2 },
    NZD = { "New Zealand Dollar",   "NZ$",    2 },
    SEK = { "Swedish Krona",        "kr",     2 },
    NOK = { "Norwegian Krone",      "kr",     2 },
    DKK = { "Danish Krone",         "kr",     2 },
    ISK = { "Icelandic Krona",      "kr",     0 },
    PLN = { "Polish Zloty",         "zł",     2 },
    CZK = { "Czech Koruna",         "Kč",     2 },
    HUF = { "Hungarian Forint",     "Ft",     2 },
    RON = { "Romanian Leu",         "lei",    2 },
    BGN = { "Bulgarian Lev",        "лв",     2 },
    HRK = { "Croatian Kuna",        "kn",     2 },
    RUB = { "Russian Ruble",        "₽",      2 },
    UAH = { "Ukrainian Hryvnia",    "₴",      2 },
    TRY = { "Turkish Lira",         "₺",      2 },
    INR = { "Indian Rupee",         "₹",      2 },
    PKR = { "Pakistani Rupee",      "₨",      2 },
    BDT = { "Bangladeshi Taka",     "৳",      2 },
    LKR = { "Sri Lankan Rupee",     "₨",      2 },
    NPR = { "Nepalese Rupee",       "₨",      2 },
    AED = { "UAE Dirham",           "د.إ",    2 },
    SAR = { "Saudi Riyal",          "﷼",      2 },
    QAR = { "Qatari Riyal",         "﷼",      2 },
    KWD = { "Kuwaiti Dinar",        "د.ك",    3 },
    BHD = { "Bahraini Dinar",       ".د.ب",   3 },
    OMR = { "Omani Rial",           "﷼",      3 },
    JOD = { "Jordanian Dinar",      "د.ا",    3 },
    ILS = { "Israeli New Shekel",   "₪",      2 },
    EGP = { "Egyptian Pound",       "£",      2 },
    ZAR = { "South African Rand",   "R",      2 },
    NGN = { "Nigerian Naira",       "₦",      2 },
    KES = { "Kenyan Shilling",      "KSh",    2 },
    GHS = { "Ghanaian Cedi",        "₵",      2 },
    MAD = { "Moroccan Dirham",      "د.م.",   2 },
    DZD = { "Algerian Dinar",       "د.ج",    2 },
    TND = { "Tunisian Dinar",       "د.ت",    3 },
    ARS = { "Argentine Peso",       "$",      2 },
    BRL = { "Brazilian Real",       "R$",     2 },
    CLP = { "Chilean Peso",         "$",      0 },
    COP = { "Colombian Peso",       "$",      2 },
    MXN = { "Mexican Peso",         "$",      2 },
    PEN = { "Peruvian Sol",         "S/",     2 },
    UYU = { "Uruguayan Peso",       "$U",     2 },
    VES = { "Venezuelan Bolivar",   "Bs",     2 },
    THB = { "Thai Baht",            "฿",      2 },
    VND = { "Vietnamese Dong",      "₫",      0 },
    IDR = { "Indonesian Rupiah",    "Rp",     2 },
    MYR = { "Malaysian Ringgit",    "RM",     2 },
    PHP = { "Philippine Peso",      "₱",      2 },
    KRW = { "South Korean Won",     "₩",      0 },
    TWD = { "New Taiwan Dollar",    "NT$",    2 },
    BTC = { "Bitcoin",              "₿",      8 },
    ETH = { "Ether",                "Ξ",      18 },
}

-- ===== Exchange rates =================================================
-- Default seed: USD-relative snapshot (illustrative — not live).
-- Users SHOULD call set_rates() or set_rate_provider() in production.

local RATES = {
    base = "USD",
    rates = {
        USD = 1.0,
        EUR = 0.92,
        GBP = 0.79,
        JPY = 156.0,
        CNY = 7.25,
        HKD = 7.81,
        SGD = 1.35,
        CHF = 0.91,
        CAD = 1.36,
        AUD = 1.51,
        NZD = 1.63,
        SEK = 10.45,
        NOK = 10.78,
        DKK = 6.88,
        ISK = 138.0,
        PLN = 4.02,
        CZK = 23.15,
        HUF = 360.0,
        RON = 4.58,
        BGN = 1.80,
        RUB = 88.5,
        UAH = 39.5,
        TRY = 32.4,
        INR = 83.4,
        PKR = 278.0,
        BDT = 117.0,
        LKR = 305.0,
        NPR = 133.5,
        AED = 3.67,
        SAR = 3.75,
        QAR = 3.64,
        KWD = 0.307,
        BHD = 0.377,
        OMR = 0.385,
        JOD = 0.709,
        ILS = 3.71,
        EGP = 47.0,
        ZAR = 18.7,
        NGN = 1505.0,
        KES = 130.0,
        GHS = 14.3,
        MAD = 9.95,
        DZD = 134.0,
        TND = 3.10,
        ARS = 880.0,
        BRL = 5.10,
        CLP = 920.0,
        COP = 3950.0,
        MXN = 17.0,
        PEN = 3.75,
        UYU = 38.6,
        VES = 36.5,
        THB = 36.5,
        VND = 25400.0,
        IDR = 16100.0,
        MYR = 4.72,
        PHP = 58.2,
        KRW = 1360.0,
        TWD = 32.3,
        HRK = 6.93,
        BTC = 0.0000156,
        ETH = 0.000345,
    },
}

local RATE_PROVIDER = nil

function M.set_rates(rate_table)
    if type(rate_table) ~= "table" or type(rate_table.rates) ~= "table" then
        error("currency.set_rates: expected { base=..., rates={...} }")
    end
    RATES = { base = rate_table.base or "USD", rates = {} }
    for k, v in pairs(rate_table.rates) do RATES.rates[k] = v end
    -- Ensure base is 1.0.
    RATES.rates[RATES.base] = 1.0
end

function M.set_rate_provider(fn)
    if fn ~= nil and type(fn) ~= "function" then
        error("currency.set_rate_provider: expected function or nil")
    end
    RATE_PROVIDER = fn
end

function M.rate(from, to)
    if RATE_PROVIDER then
        local ok, r = pcall(RATE_PROVIDER, from, to)
        if ok and type(r) == "number" then return r end
    end
    local rf = RATES.rates[from]
    local rt = RATES.rates[to]
    if not rf then error("currency: no rate for '" .. from .. "'") end
    if not rt then error("currency: no rate for '" .. to   .. "'") end
    -- rf = units of from per base; rt = units of to per base.
    -- 1 from = (1/rf) base = (rt/rf) to.
    return rt / rf
end

function M.convert(amount, from, to, rate)
    if from == to then return amount end
    local r = rate or M.rate(from, to)
    return amount * r
end

-- ===== Metadata lookups ===============================================

function M.is_valid(code)
    return CUR[code] ~= nil
end

function M.currencies()
    local out = {}
    for code, meta in pairs(CUR) do
        out[#out + 1] = {
            code     = code,
            name     = meta[1],
            symbol   = meta[2],
            decimals = meta[3],
        }
    end
    table.sort(out, function(a, b) return a.code < b.code end)
    return out
end

function M.info(code)
    local meta = CUR[code]
    if not meta then return nil end
    return { code = code, name = meta[1], symbol = meta[2], decimals = meta[3] }
end

-- ===== Locales ========================================================

local LOCALES = {
    ["en-US"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["en-GB"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["en-CA"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["en-AU"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["en-IN"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3, india_grouping = true },
    ["de-DE"] = { decimal = ",", thousand = ".", symbol_position = "after",
                  grouping = 3 },
    ["de-AT"] = { decimal = ",", thousand = ".", symbol_position = "before",
                  grouping = 3 },
    ["de-CH"] = { decimal = ".", thousand = "'", symbol_position = "before",
                  grouping = 3 },
    ["fr-FR"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["fr-CA"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["it-IT"] = { decimal = ",", thousand = ".", symbol_position = "before",
                  grouping = 3 },
    ["es-ES"] = { decimal = ",", thousand = ".", symbol_position = "after",
                  grouping = 3 },
    ["es-MX"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["pt-BR"] = { decimal = ",", thousand = ".", symbol_position = "before",
                  grouping = 3 },
    ["pt-PT"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["nl-NL"] = { decimal = ",", thousand = ".", symbol_position = "before",
                  grouping = 3 },
    ["ru-RU"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["pl-PL"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["sv-SE"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["no-NO"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["da-DK"] = { decimal = ",", thousand = ".", symbol_position = "after",
                  grouping = 3 },
    ["fi-FI"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["ja-JP"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["zh-CN"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["zh-TW"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["ko-KR"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["ar-SA"] = { decimal = ".", thousand = ",", symbol_position = "after",
                  grouping = 3 },
    ["he-IL"] = { decimal = ".", thousand = ",", symbol_position = "before",
                  grouping = 3 },
    ["tr-TR"] = { decimal = ",", thousand = ".", symbol_position = "after",
                  grouping = 3 },
    ["cs-CZ"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["hu-HU"] = { decimal = ",", thousand = " ", symbol_position = "after",
                  grouping = 3 },
    ["el-GR"] = { decimal = ",", thousand = ".", symbol_position = "after",
                  grouping = 3 },
}

function M.locale(name) return LOCALES[name] end

-- ===== Formatting =====================================================

local function group_int(int_str, sep, grouping, india_grouping)
    if sep == "" or sep == nil then return int_str end
    -- India grouping: 3 then 2s (e.g., 12,34,567.89).
    if india_grouping then
        if #int_str <= 3 then return int_str end
        local last3 = int_str:sub(-3)
        local rest  = int_str:sub(1, -4)
        local parts = {}
        local i = #rest
        while i > 0 do
            local lo = math.max(1, i - 1)
            parts[#parts + 1] = rest:sub(lo, i)
            i = lo - 1
        end
        local rev = {}
        for k = #parts, 1, -1 do rev[#rev + 1] = parts[k] end
        return table.concat(rev, sep) .. sep .. last3
    end
    -- Standard western grouping.
    local rev = int_str:reverse()
    local grouped = rev:gsub("(" .. ("."):rep(grouping) .. ")", "%1" .. sep)
    grouped = grouped:reverse()
    if grouped:sub(1, #sep) == sep then grouped = grouped:sub(#sep + 1) end
    return grouped
end

function M.format(amount, code, opts)
    opts = opts or {}
    if type(amount) ~= "number" then
        error("currency.format: amount must be a number")
    end
    if not code or not CUR[code] then
        error("currency.format: unknown currency '" .. tostring(code) .. "'")
    end
    local meta = CUR[code]
    local sym  = meta[2]
    local def_dec = meta[3]

    local loc = opts.locale and LOCALES[opts.locale] or LOCALES["en-US"]
    local decimal     = opts.decimal_sep   or loc.decimal
    local thousand    = opts.thousand_sep  or loc.thousand
    local sym_pos     = opts.symbol_position or loc.symbol_position
    local show_code   = opts.show_code or false
    local decimals    = opts.decimal_places
    if decimals == nil then decimals = def_dec end

    local sign = ""
    local abs_v = amount
    if amount < 0 then sign = "-"; abs_v = -amount end

    -- A double carries ~15 faithful significant decimal digits; asking for more
    -- fractional places (e.g. ETH's 18) just prints IEEE-754 low-order garbage.
    -- Clamp the displayed fraction so total significant digits stay <= 15 (the
    -- integer part's digit count eats into that budget) and, when we had to
    -- clamp, drop the now-meaningless trailing zeros so the result is clean.
    -- USD 2dp / BTC 8dp at normal magnitudes never hit the cap, so fixed-point
    -- currencies are left exactly as before (e.g. "$1.50" keeps its trailing 0).
    local clamped = false
    if abs_v ~= abs_v or abs_v == math.huge then
        -- nan/inf: let string.format render it as-is.
    else
        local int_digits = (abs_v >= 1) and #tostring(math.floor(abs_v)) or 0
        local safe_dec = 15 - int_digits
        if safe_dec < 0 then safe_dec = 0 end
        if decimals > safe_dec then decimals = safe_dec; clamped = true end
    end

    local s = string.format("%." .. decimals .. "f", abs_v)
    if clamped and s:find("%.") then
        s = s:gsub("0+$", ""):gsub("%.$", "")
    end
    local int_part, frac_part = s:match("^(%d+)%.?(%d*)$")
    int_part = group_int(int_part or s, thousand, loc.grouping or 3, loc.india_grouping)

    local num_str = int_part
    if frac_part and #frac_part > 0 then
        num_str = int_part .. decimal .. frac_part
    end

    local body
    if show_code then
        if sym_pos == "after" then body = num_str .. " " .. code
        else                        body = code .. " " .. num_str end
    else
        if sym_pos == "after" then body = num_str .. " " .. sym
        else                        body = sym .. num_str end
    end

    return sign .. body
end

-- ===== Parsing =========================================================

local SYMBOL_TO_CODE = nil

local function build_symbol_map()
    if SYMBOL_TO_CODE then return end
    SYMBOL_TO_CODE = {}
    -- Build only for unambiguous symbols. Avoid clashes (e.g., $ used by many).
    local counts = {}
    for code, meta in pairs(CUR) do
        local sym = meta[2]
        counts[sym] = (counts[sym] or 0) + 1
    end
    for code, meta in pairs(CUR) do
        local sym = meta[2]
        if counts[sym] == 1 then SYMBOL_TO_CODE[sym] = code end
    end
    -- Add a couple of canonical aliases for ambiguous ones with a sensible default.
    SYMBOL_TO_CODE["$"]  = SYMBOL_TO_CODE["$"]  or "USD"
    SYMBOL_TO_CODE["£"]  = SYMBOL_TO_CODE["£"]  or "GBP"
    SYMBOL_TO_CODE["¥"]  = SYMBOL_TO_CODE["¥"]  or "JPY"
end

local function strip_separators(numstr)
    -- Decide which is decimal: if there's both '.' and ',', the rightmost wins.
    -- If only one is present, treat it as decimal iff it appears once and has
    -- 1-3 trailing digits, else thousand.
    local last_dot   = numstr:find("%.[^.]*$")
    local last_comma = numstr:find(",[^,]*$")
    local dec_idx, dec_char
    if last_dot and last_comma then
        if last_dot > last_comma then
            dec_idx, dec_char = last_dot, "."
        else
            dec_idx, dec_char = last_comma, ","
        end
    elseif last_dot then
        local _, count = numstr:gsub("%.", "")
        local tail = numstr:sub(last_dot + 1)
        if count == 1 and #tail ~= 3 then dec_idx, dec_char = last_dot, "."
        else dec_idx, dec_char = nil, nil end
    elseif last_comma then
        local _, count = numstr:gsub(",", "")
        local tail = numstr:sub(last_comma + 1)
        if count == 1 and #tail ~= 3 then dec_idx, dec_char = last_comma, ","
        else dec_idx, dec_char = nil, nil end
    end

    local int_part, frac_part
    if dec_idx then
        int_part  = numstr:sub(1, dec_idx - 1)
        frac_part = numstr:sub(dec_idx + 1)
    else
        int_part  = numstr
        frac_part = nil
    end
    -- Strip all dots, commas, spaces from int_part.
    int_part = int_part:gsub("[%.,%s]", "")
    if frac_part then
        return int_part .. "." .. frac_part
    end
    return int_part
end

function M.parse(text)
    if type(text) ~= "string" then
        error("currency.parse: expected string")
    end
    build_symbol_map()
    local s = text:gsub("^%s+", ""):gsub("%s+$", "")
    local sign = ""
    if s:sub(1,1) == "-" then sign = "-"; s = s:sub(2):gsub("^%s+", "") end
    if s:sub(1,1) == "+" then s = s:sub(2):gsub("^%s+", "") end

    -- Match a 3-letter ISO code at start or end.
    local code_at_start = s:match("^(%u%u%u)%s+")
    local code_at_end   = s:match("%s+(%u%u%u)$")
    local code = nil
    local rest = s

    if code_at_start and CUR[code_at_start] then
        code = code_at_start
        rest = s:sub(4):gsub("^%s+", "")
    elseif code_at_end and CUR[code_at_end] then
        code = code_at_end
        rest = s:sub(1, -5):gsub("%s+$", "")
    else
        -- Try to find a symbol at start or end.
        for sym, c in pairs(SYMBOL_TO_CODE) do
            if s:sub(1, #sym) == sym then
                code = c
                rest = s:sub(#sym + 1):gsub("^%s+", "")
                break
            elseif s:sub(-#sym) == sym then
                code = c
                rest = s:sub(1, -#sym - 1):gsub("%s+$", "")
                break
            end
        end
    end

    -- Rest should be a number with possible thousand/decimal separators.
    local num_part = rest:match("^[%d%.,%s]+$")
    if not num_part then
        error("currency.parse: cannot identify amount in '" .. text .. "'")
    end
    local norm = strip_separators(num_part)
    local n = tonumber(sign .. norm)
    if not n then
        error("currency.parse: bad number in '" .. text .. "'")
    end
    return { amount = n, currency = code }
end

return M
