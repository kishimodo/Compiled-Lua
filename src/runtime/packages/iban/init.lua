-- iban -- ISO 13616 IBAN validation, parsing, formatting.
--
-- Public surface:
--   iban.is_valid(s)                  -> bool
--   iban.validate(s)                  -> ok, country, check_digits | nil, err
--   iban.format(s)                    -> "GB82 WEST 1234 5698 7654 32"
--   iban.parse(s)                     -> { country, check_digits, bban,
--                                          bank_code, branch_code,
--                                          account_number }
--   iban.countries                    -> table of country -> {length, pattern,
--                                                              bank_pos, branch_pos,
--                                                              account_pos}

local M = {}

-- ===== Country specs ===================================================
--
-- Each entry: {
--   length     = total IBAN length,
--   bban       = BBAN structure pattern in ISO 13616 short form
--                ( "n" digit, "a" letter, "c" alphanumeric; preceded by length )
--   bank       = { lo, hi } position within BBAN (1-based, inclusive) | nil
--   branch     = { lo, hi } | nil
--   account    = { lo, hi } | nil
-- }
--
-- Positions are 1-based offsets within the BBAN (i.e. after the first 4
-- chars: 2 country letters + 2 check digits).

local C = {}

local function spec(len, bban, bank, branch, account)
    return { length = len, bban = bban, bank = bank, branch = branch, account = account }
end

C.AD = spec(24, "4!n4!n12!c",  {1,4},  {5,8},  {9,20})
C.AE = spec(23, "3!n16!n",     {1,3},  nil,    {4,19})
C.AL = spec(28, "8!n16!c",     {1,3},  {4,8},  {9,24})
C.AT = spec(20, "5!n11!n",     {1,5},  nil,    {6,16})
C.AZ = spec(28, "4!a20!c",     {1,4},  nil,    {5,24})
C.BA = spec(20, "3!n3!n8!n2!n",{1,3},  {4,6},  {7,14})
C.BE = spec(16, "3!n7!n2!n",   {1,3},  nil,    {4,12})
C.BG = spec(22, "4!a4!n2!n8!c",{1,4},  {5,8},  {11,18})
C.BH = spec(22, "4!a14!c",     {1,4},  nil,    {5,18})
C.BR = spec(29, "8!n5!n10!n1!a1!c",{1,8},{9,13},{14,23})
C.BY = spec(28, "4!c4!n16!c",  {1,4},  nil,    {9,24})
C.CH = spec(21, "5!n12!c",     {1,5},  nil,    {6,17})
C.CR = spec(22, "4!n14!n",     {1,4},  nil,    {5,18})
C.CY = spec(28, "3!n5!n16!c",  {1,3},  {4,8},  {9,24})
C.CZ = spec(24, "4!n6!n10!n",  {1,4},  nil,    {5,20})
C.DE = spec(22, "8!n10!n",     {1,8},  nil,    {9,18})
C.DK = spec(18, "4!n9!n1!n",   {1,4},  nil,    {5,14})
C.DO = spec(28, "4!c20!n",     {1,4},  nil,    {5,24})
C.EE = spec(20, "2!n2!n11!n1!n",{1,2}, nil,    {3,16})
C.EG = spec(29, "4!n4!n17!n",  {1,4},  {5,8},  {9,25})
C.ES = spec(24, "4!n4!n1!n1!n10!n",{1,4},{5,8},{11,20})
C.FI = spec(18, "3!n11!n",     {1,3},  nil,    {4,14})
C.FO = spec(18, "4!n9!n1!n",   {1,4},  nil,    {5,14})
C.FR = spec(27, "5!n5!n11!c2!n",{1,5}, {6,10}, {11,21})
C.GB = spec(22, "4!a6!n8!n",   {1,4},  {5,10}, {11,18})
C.GE = spec(22, "2!a16!n",     {1,2},  nil,    {3,18})
C.GI = spec(23, "4!a15!c",     {1,4},  nil,    {5,19})
C.GL = spec(18, "4!n9!n1!n",   {1,4},  nil,    {5,14})
C.GR = spec(27, "3!n4!n16!c",  {1,3},  {4,7},  {8,23})
C.GT = spec(28, "4!c20!c",     {1,4},  nil,    {5,24})
C.HR = spec(21, "7!n10!n",     {1,7},  nil,    {8,17})
C.HU = spec(28, "3!n4!n1!n15!n1!n",{1,3},{4,7},{9,23})
C.IE = spec(22, "4!a6!n8!n",   {1,4},  {5,10}, {11,18})
C.IL = spec(23, "3!n3!n13!n",  {1,3},  {4,6},  {7,19})
C.IQ = spec(23, "4!a3!n12!n",  {1,4},  {5,7},  {8,19})
C.IS = spec(26, "4!n2!n6!n10!n",{1,4}, nil,    {5,22})
C.IT = spec(27, "1!a5!n5!n12!c",{2,6}, {7,11}, {12,23})
C.JO = spec(30, "4!a4!n18!c",  {1,4},  {5,8},  {9,26})
C.KW = spec(30, "4!a22!c",     {1,4},  nil,    {5,26})
C.KZ = spec(20, "3!n13!c",     {1,3},  nil,    {4,16})
C.LB = spec(28, "4!n20!c",     {1,4},  nil,    {5,24})
C.LC = spec(32, "4!a24!c",     {1,4},  nil,    {5,28})
C.LI = spec(21, "5!n12!c",     {1,5},  nil,    {6,17})
C.LT = spec(20, "5!n11!n",     {1,5},  nil,    {6,16})
C.LU = spec(20, "3!n13!c",     {1,3},  nil,    {4,16})
C.LV = spec(21, "4!a13!c",     {1,4},  nil,    {5,17})
C.MC = spec(27, "5!n5!n11!c2!n",{1,5}, {6,10}, {11,21})
C.MD = spec(24, "2!c18!c",     {1,2},  nil,    {3,20})
C.ME = spec(22, "3!n13!n2!n",  {1,3},  nil,    {4,16})
C.MK = spec(19, "3!n10!c2!n",  {1,3},  nil,    {4,13})
C.MR = spec(27, "5!n5!n11!n2!n",{1,5}, {6,10}, {11,21})
C.MT = spec(31, "4!a5!n18!c",  {1,4},  {5,9},  {10,27})
C.MU = spec(30, "4!a2!n2!n12!n3!n3!a",{1,4},{5,8},{9,26})
C.NL = spec(18, "4!a10!n",     {1,4},  nil,    {5,14})
C.NO = spec(15, "4!n6!n1!n",   {1,4},  nil,    {5,11})
C.PK = spec(24, "4!a16!c",     {1,4},  nil,    {5,20})
C.PL = spec(28, "8!n16!n",     {1,8},  nil,    {9,24})
C.PS = spec(29, "4!a21!c",     {1,4},  nil,    {5,25})
C.PT = spec(25, "4!n4!n11!n2!n",{1,4}, {5,8},  {9,19})
C.QA = spec(29, "4!a21!c",     {1,4},  nil,    {5,25})
C.RO = spec(24, "4!a16!c",     {1,4},  nil,    {5,20})
C.RS = spec(22, "3!n13!n2!n",  {1,3},  nil,    {4,16})
C.SA = spec(24, "2!n18!c",     {1,2},  nil,    {3,20})
C.SC = spec(31, "4!a4!n16!n3!a",{1,4}, {5,8},  {9,24})
C.SE = spec(24, "3!n16!n1!n",  {1,3},  nil,    {4,19})
C.SI = spec(19, "5!n8!n2!n",   {1,5},  nil,    {6,13})
C.SK = spec(24, "4!n6!n10!n",  {1,4},  nil,    {5,20})
C.SM = spec(27, "1!a5!n5!n12!c",{2,6}, {7,11}, {12,23})
C.ST = spec(25, "8!n11!n2!n",  {1,8},  nil,    {9,19})
C.SV = spec(28, "4!a20!n",     {1,4},  nil,    {5,24})
C.TL = spec(23, "3!n14!n2!n",  {1,3},  nil,    {4,17})
C.TN = spec(24, "2!n3!n13!n2!n",{1,2}, {3,5},  {6,18})
C.TR = spec(26, "5!n1!c16!c",  {1,5},  nil,    {7,22})
C.UA = spec(29, "6!n19!c",     {1,6},  nil,    {7,25})
C.VA = spec(22, "3!n15!n",     {1,3},  nil,    {4,18})
C.VG = spec(24, "4!a16!n",     {1,4},  nil,    {5,20})
C.XK = spec(20, "4!n10!n2!n",  {1,4},  nil,    {5,14})

M.countries = C

-- ===== Helpers ==========================================================

local function strip(iban)
    if type(iban) ~= "string" then return "" end
    iban = iban:upper():gsub("[%s%-]", "")
    return iban
end

local function is_alnum(b)
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90)
end

-- mod-97 check digit. Per ISO 13616: move first 4 chars to end, replace
-- letters with 2-digit codes (A=10..Z=35), reduce mod 97; must equal 1.
-- We process digit-by-digit to keep within Lua integer range.

local function mod97(s)
    local r = 0
    for i = 1, #s do
        local b = s:byte(i)
        local v
        if b >= 48 and b <= 57 then
            v = b - 48
            r = (r * 10 + v) % 97
        elseif b >= 65 and b <= 90 then
            v = b - 55  -- 'A' -> 10
            r = (r * 100 + v) % 97  -- two digit substitution
        else
            return -1
        end
    end
    return r
end

local function expand_pattern(pat)
    -- Parse "4!n4!n12!c" into a sequence of { len, kind }.
    local out = {}
    local i = 1
    while i <= #pat do
        local n, kind = pat:match("^(%d+)!([nac])", i)
        if not n then return nil end
        out[#out + 1] = { tonumber(n), kind }
        i = i + #n + 2
    end
    return out
end

local function pattern_matches(bban, parts)
    local pos = 1
    for _, p in ipairs(parts) do
        local len, kind = p[1], p[2]
        if pos + len - 1 > #bban then return false end
        for k = pos, pos + len - 1 do
            local b = bban:byte(k)
            if kind == "n" then
                if not (b >= 48 and b <= 57) then return false end
            elseif kind == "a" then
                if not (b >= 65 and b <= 90) then return false end
            elseif kind == "c" then
                if not is_alnum(b) then return false end
            end
        end
        pos = pos + len
    end
    return pos - 1 == #bban
end

-- ===== Public functions ================================================

function M.validate(s)
    s = strip(s)
    if #s < 5 then return nil, "too short" end
    local country = s:sub(1, 2)
    local entry = C[country]
    if not entry then return nil, "unknown country: " .. country end
    if #s ~= entry.length then
        return nil, ("bad length: got %d want %d"):format(#s, entry.length)
    end
    local check_digits = s:sub(3, 4)
    if not check_digits:match("^%d%d$") then
        return nil, "non-digit check"
    end
    -- BBAN structure check.
    local bban = s:sub(5)
    local parts = expand_pattern(entry.bban)
    if not parts or not pattern_matches(bban, parts) then
        return nil, "bban structure mismatch"
    end
    -- Mod-97 check.
    local rearranged = s:sub(5) .. s:sub(1, 4)
    local r = mod97(rearranged)
    if r ~= 1 then return nil, "mod-97 fail" end
    return true, country, check_digits
end

function M.is_valid(s)
    return (M.validate(s)) == true
end

function M.format(s)
    s = strip(s)
    if s == "" then return "" end
    local out = {}
    for i = 1, #s, 4 do
        out[#out + 1] = s:sub(i, i + 3)
    end
    return table.concat(out, " ")
end

local function slice(bban, range)
    if not range then return nil end
    return bban:sub(range[1], range[2])
end

function M.parse(s)
    local ok, country, check_digits = M.validate(s)
    if not ok then return nil, country end  -- country holds error here
    s = strip(s)
    local bban = s:sub(5)
    local entry = C[country]
    return {
        country        = country,
        check_digits   = check_digits,
        bban           = bban,
        bank_code      = slice(bban, entry.bank),
        branch_code    = slice(bban, entry.branch),
        account_number = slice(bban, entry.account),
    }
end

-- Convenience: compute the correct two check digits for a candidate IBAN
-- whose check positions are "00" (useful for generators/tests).
function M.checksum(candidate)
    candidate = strip(candidate)
    if #candidate < 5 then return nil, "too short" end
    local cc = candidate:sub(1, 2)
    local entry = C[cc]
    if not entry or #candidate ~= entry.length then
        return nil, "bad length"
    end
    local probe = candidate:sub(5) .. cc .. "00"
    local r = mod97(probe)
    if r < 0 then return nil, "non-alphanumeric" end
    local digits = 98 - r
    return string.format("%02d", digits)
end

return M
