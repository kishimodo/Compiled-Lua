-- phone -- E.164 phone-number parsing, validation, formatting.
--
-- Public surface:
--   phone.parse(input, default_country?) -> {
--       country_code, national_number, e164, valid, type, country, region
--   } | nil, err
--   phone.format(parsed, fmt)           -> string
--       fmt = "e164" | "international" | "national" | "rfc3966"
--   phone.is_valid(input, country?)     -> bool
--   phone.country_code(input)           -> calling-code string | nil
--
-- "country" is an ISO 3166-1 alpha-2 code (e.g. "US", "DE", "JP").
-- "default_country" is used to interpret numbers given without a leading
-- "+" or "00" international prefix.

local M = {}

-- ===== Country / calling-code table ===================================
--
-- Each entry: { iso2, calling_code, min_natlen, max_natlen, region }
-- The table is intentionally compact. Multiple ISO codes can share a
-- calling code (NANP +1 covers US/CA/many Caribbean territories).

local COUNTRIES = {
    -- North America
    { "US",  "1",   10, 10, "North America" },
    { "CA",  "1",   10, 10, "North America" },
    { "JM",  "1",   10, 10, "Caribbean" },
    { "BS",  "1",   10, 10, "Caribbean" },
    { "BB",  "1",   10, 10, "Caribbean" },
    { "PR",  "1",   10, 10, "Caribbean" },
    { "DO",  "1",   10, 10, "Caribbean" },
    -- Europe (+3x/+4x)
    { "GR",  "30",  10, 10, "Europe" },
    { "NL",  "31",  9,  9,  "Europe" },
    { "BE",  "32",  8,  9,  "Europe" },
    { "FR",  "33",  9,  9,  "Europe" },
    { "ES",  "34",  9,  9,  "Europe" },
    { "HU",  "36",  8,  9,  "Europe" },
    { "IT",  "39",  9,  11, "Europe" },
    { "RO",  "40",  9,  9,  "Europe" },
    { "CH",  "41",  9,  9,  "Europe" },
    { "AT",  "43",  4,  13, "Europe" },
    { "GB",  "44",  9,  10, "Europe" },
    { "DK",  "45",  8,  8,  "Europe" },
    { "SE",  "46",  6,  10, "Europe" },
    { "NO",  "47",  8,  8,  "Europe" },
    { "PL",  "48",  9,  9,  "Europe" },
    { "DE",  "49",  6,  13, "Europe" },
    { "PE",  "51",  8,  11, "South America" },
    { "MX",  "52",  10, 11, "North America" },
    { "CU",  "53",  6,  8,  "Caribbean" },
    { "AR",  "54",  10, 11, "South America" },
    { "BR",  "55",  10, 11, "South America" },
    { "CL",  "56",  9,  9,  "South America" },
    { "CO",  "57",  10, 10, "South America" },
    { "VE",  "58",  10, 10, "South America" },
    { "MY",  "60",  7,  10, "Asia" },
    { "AU",  "61",  9,  9,  "Oceania" },
    { "ID",  "62",  9,  11, "Asia" },
    { "PH",  "63",  10, 10, "Asia" },
    { "NZ",  "64",  3,  10, "Oceania" },
    { "SG",  "65",  8,  8,  "Asia" },
    { "TH",  "66",  8,  9,  "Asia" },
    { "JP",  "81",  10, 10, "Asia" },
    { "KR",  "82",  9,  10, "Asia" },
    { "VN",  "84",  9,  10, "Asia" },
    { "CN",  "86",  11, 11, "Asia" },
    { "TR",  "90",  10, 10, "Asia" },
    { "IN",  "91",  10, 10, "Asia" },
    { "PK",  "92",  10, 10, "Asia" },
    { "AF",  "93",  9,  9,  "Asia" },
    { "LK",  "94",  9,  9,  "Asia" },
    { "MM",  "95",  7,  10, "Asia" },
    { "IR",  "98",  10, 10, "Asia" },
    -- 2xx / 3-digit codes
    { "EG",  "20",  9,  10, "Africa" },
    { "ZA",  "27",  9,  9,  "Africa" },
    { "MA",  "212", 9,  9,  "Africa" },
    { "DZ",  "213", 9,  9,  "Africa" },
    { "TN",  "216", 8,  8,  "Africa" },
    { "LY",  "218", 8,  9,  "Africa" },
    { "GM",  "220", 7,  7,  "Africa" },
    { "SN",  "221", 9,  9,  "Africa" },
    { "MR",  "222", 8,  8,  "Africa" },
    { "ML",  "223", 8,  8,  "Africa" },
    { "GN",  "224", 8,  9,  "Africa" },
    { "CI",  "225", 10, 10, "Africa" },
    { "BF",  "226", 8,  8,  "Africa" },
    { "NE",  "227", 8,  8,  "Africa" },
    { "TG",  "228", 8,  8,  "Africa" },
    { "BJ",  "229", 8,  8,  "Africa" },
    { "MU",  "230", 7,  8,  "Africa" },
    { "LR",  "231", 7,  8,  "Africa" },
    { "SL",  "232", 8,  8,  "Africa" },
    { "GH",  "233", 9,  9,  "Africa" },
    { "NG",  "234", 7,  10, "Africa" },
    { "TD",  "235", 8,  8,  "Africa" },
    { "CF",  "236", 8,  8,  "Africa" },
    { "CM",  "237", 9,  9,  "Africa" },
    { "CV",  "238", 7,  7,  "Africa" },
    { "ST",  "239", 7,  7,  "Africa" },
    { "GQ",  "240", 9,  9,  "Africa" },
    { "GA",  "241", 7,  8,  "Africa" },
    { "CG",  "242", 9,  9,  "Africa" },
    { "CD",  "243", 9,  9,  "Africa" },
    { "AO",  "244", 9,  9,  "Africa" },
    { "GW",  "245", 7,  7,  "Africa" },
    { "SC",  "248", 7,  7,  "Africa" },
    { "SD",  "249", 9,  9,  "Africa" },
    { "RW",  "250", 9,  9,  "Africa" },
    { "ET",  "251", 9,  9,  "Africa" },
    { "SO",  "252", 7,  9,  "Africa" },
    { "DJ",  "253", 8,  8,  "Africa" },
    { "KE",  "254", 9,  10, "Africa" },
    { "TZ",  "255", 9,  9,  "Africa" },
    { "UG",  "256", 9,  9,  "Africa" },
    { "BI",  "257", 8,  8,  "Africa" },
    { "MZ",  "258", 8,  9,  "Africa" },
    { "ZM",  "260", 9,  9,  "Africa" },
    { "MG",  "261", 9,  9,  "Africa" },
    { "ZW",  "263", 5,  10, "Africa" },
    { "NA",  "264", 7,  10, "Africa" },
    { "MW",  "265", 7,  9,  "Africa" },
    { "LS",  "266", 8,  8,  "Africa" },
    { "BW",  "267", 7,  8,  "Africa" },
    { "SZ",  "268", 7,  8,  "Africa" },
    { "KM",  "269", 7,  7,  "Africa" },
    -- 3xx Europe minors
    { "PT",  "351", 9,  9,  "Europe" },
    { "LU",  "352", 4,  11, "Europe" },
    { "IE",  "353", 7,  11, "Europe" },
    { "IS",  "354", 7,  9,  "Europe" },
    { "AL",  "355", 3,  9,  "Europe" },
    { "MT",  "356", 8,  8,  "Europe" },
    { "CY",  "357", 8,  8,  "Europe" },
    { "FI",  "358", 5,  12, "Europe" },
    { "BG",  "359", 5,  9,  "Europe" },
    { "LT",  "370", 8,  8,  "Europe" },
    { "LV",  "371", 7,  8,  "Europe" },
    { "EE",  "372", 7,  8,  "Europe" },
    { "MD",  "373", 8,  8,  "Europe" },
    { "AM",  "374", 8,  8,  "Asia" },
    { "BY",  "375", 9,  10, "Europe" },
    { "AD",  "376", 6,  9,  "Europe" },
    { "MC",  "377", 5,  9,  "Europe" },
    { "SM",  "378", 6,  10, "Europe" },
    { "UA",  "380", 9,  9,  "Europe" },
    { "RS",  "381", 4,  12, "Europe" },
    { "ME",  "382", 4,  12, "Europe" },
    { "XK",  "383", 8,  8,  "Europe" },
    { "HR",  "385", 8,  12, "Europe" },
    { "SI",  "386", 8,  8,  "Europe" },
    { "BA",  "387", 8,  8,  "Europe" },
    { "MK",  "389", 8,  8,  "Europe" },
    { "CZ",  "420", 9,  9,  "Europe" },
    { "SK",  "421", 9,  9,  "Europe" },
    { "LI",  "423", 7,  9,  "Europe" },
    -- 5xx / 8xx misc
    { "FK",  "500", 5,  5,  "South America" },
    { "BZ",  "501", 7,  7,  "Central America" },
    { "GT",  "502", 8,  8,  "Central America" },
    { "SV",  "503", 8,  8,  "Central America" },
    { "HN",  "504", 8,  8,  "Central America" },
    { "NI",  "505", 8,  8,  "Central America" },
    { "CR",  "506", 8,  8,  "Central America" },
    { "PA",  "507", 7,  8,  "Central America" },
    { "BO",  "591", 8,  9,  "South America" },
    { "EC",  "593", 8,  9,  "South America" },
    { "GY",  "592", 7,  7,  "South America" },
    { "PY",  "595", 9,  9,  "South America" },
    { "SR",  "597", 6,  7,  "South America" },
    { "UY",  "598", 8,  8,  "South America" },
    { "BN",  "673", 7,  7,  "Asia" },
    -- (Note: NANP territories such as MP +1-670 fall under "1" with 10
    --  national digits; no separate 4-digit "1670" entry, which would
    --  otherwise win longest-prefix and swallow the area code.)
    -- Middle East
    { "JO",  "962", 8,  9,  "Asia" },
    { "SY",  "963", 8,  9,  "Asia" },
    { "IQ",  "964", 10, 10, "Asia" },
    { "KW",  "965", 7,  8,  "Asia" },
    { "SA",  "966", 8,  9,  "Asia" },
    { "YE",  "967", 6,  9,  "Asia" },
    { "OM",  "968", 7,  8,  "Asia" },
    { "PS",  "970", 8,  9,  "Asia" },
    { "AE",  "971", 8,  9,  "Asia" },
    { "IL",  "972", 8,  9,  "Asia" },
    { "BH",  "973", 8,  8,  "Asia" },
    { "QA",  "974", 7,  8,  "Asia" },
    { "BT",  "975", 7,  8,  "Asia" },
    { "MN",  "976", 7,  8,  "Asia" },
    { "NP",  "977", 8,  10, "Asia" },
    { "TJ",  "992", 9,  9,  "Asia" },
    { "TM",  "993", 8,  8,  "Asia" },
    { "AZ",  "994", 8,  9,  "Asia" },
    { "GE",  "995", 9,  9,  "Asia" },
    { "KG",  "996", 9,  9,  "Asia" },
    { "UZ",  "998", 9,  9,  "Asia" },
    -- Russia / Kazakhstan
    { "RU",  "7",   10, 10, "Europe" },
    { "KZ",  "7",   10, 10, "Asia" },
}

-- Prefix-trie lookup: longest matching calling code wins.
local CC_BY_PREFIX = {}
local ISO_TO_ENTRY = {}
for _, c in ipairs(COUNTRIES) do
    CC_BY_PREFIX[c[2]] = CC_BY_PREFIX[c[2]] or c
    if not ISO_TO_ENTRY[c[1]] then ISO_TO_ENTRY[c[1]] = c end
end

local function find_calling_code(digits)
    for k = 4, 1, -1 do
        local p = digits:sub(1, k)
        if CC_BY_PREFIX[p] then return p, CC_BY_PREFIX[p] end
    end
    return nil, nil
end

-- ===== input normalization ============================================

local function strip(input)
    -- Strip everything but digits and a leading "+".
    local has_plus = input:sub(1, 1) == "+"
    local digits = (input:gsub("[^%d]", ""))
    -- "00" international prefix is equivalent to "+".
    if not has_plus and digits:sub(1, 2) == "00" then
        digits = digits:sub(3)
        has_plus = true
    end
    return has_plus, digits
end

-- Mobile-prefix heuristics for a few high-volume countries.
local function classify(country, national)
    if country == "US" or country == "CA" then
        -- NANP has no mobile/landline distinction by prefix.
        return "unknown"
    end
    if country == "GB" then
        if national:sub(1, 1) == "7" then return "mobile" end
        return "landline"
    end
    if country == "DE" then
        if national:sub(1, 3) == "15" .. "" or national:sub(1, 2) == "15"
           or national:sub(1, 2) == "16" or national:sub(1, 2) == "17" then
            return "mobile"
        end
        return "landline"
    end
    if country == "FR" then
        local p = national:sub(1, 1)
        if p == "6" or p == "7" then return "mobile" end
        return "landline"
    end
    if country == "ES" then
        local p = national:sub(1, 1)
        if p == "6" or p == "7" then return "mobile" end
        return "landline"
    end
    if country == "IN" then
        local d = tonumber(national:sub(1, 1))
        if d and d >= 6 then return "mobile" end
        return "landline"
    end
    if country == "CN" then
        if national:sub(1, 1) == "1" then return "mobile" end
        return "landline"
    end
    if country == "JP" then
        local p = national:sub(1, 2)
        if p == "70" or p == "80" or p == "90" then return "mobile" end
        return "landline"
    end
    if country == "BR" then
        -- Last 9 digits start with 9 for mobile.
        local n = national
        if #n >= 9 and n:sub(-9, -9) == "9" then return "mobile" end
        return "landline"
    end
    if country == "RU" then
        if national:sub(1, 1) == "9" then return "mobile" end
        return "landline"
    end
    return "unknown"
end

-- ===== public functions ===============================================

function M.country_code(input)
    if type(input) ~= "string" then return nil end
    local has_plus, digits = strip(input)
    if not has_plus then return nil end
    local cc = find_calling_code(digits)
    return cc
end

function M.parse(input, default_country)
    if type(input) ~= "string" or input == "" then
        return nil, "empty"
    end
    local has_plus, digits = strip(input)
    local cc, entry

    if has_plus then
        cc, entry = find_calling_code(digits)
        if not cc then return nil, "unknown calling code" end
        digits = digits:sub(#cc + 1)
    else
        if not default_country then
            return nil, "no '+' and no default_country"
        end
        entry = ISO_TO_ENTRY[default_country]
        if not entry then return nil, "unknown default_country" end
        cc = entry[2]
        -- Strip a national trunk prefix "0" for many countries.
        if digits:sub(1, 1) == "0" then digits = digits:sub(2) end
    end

    local national = digits
    local len_ok = (#national >= entry[3] and #national <= entry[4])
    local e164 = "+" .. cc .. national

    return {
        country_code    = cc,
        national_number = national,
        e164            = e164,
        valid           = len_ok and #national > 0,
        type            = len_ok and classify(entry[1], national) or "unknown",
        country         = entry[1],
        region          = entry[5],
    }
end

function M.is_valid(input, country)
    local p, _ = M.parse(input, country)
    if not p then return false end
    return p.valid
end

function M.format(parsed, fmt)
    if type(parsed) == "string" then
        local p, err = M.parse(parsed)
        if not p then return nil, err end
        parsed = p
    end
    fmt = fmt or "e164"
    if fmt == "e164" then
        return parsed.e164
    elseif fmt == "international" then
        return "+" .. parsed.country_code .. " " .. parsed.national_number
    elseif fmt == "national" then
        return parsed.national_number
    elseif fmt == "rfc3966" then
        return "tel:" .. parsed.e164
    end
    return nil, "unknown format"
end

M.countries = COUNTRIES

return M
