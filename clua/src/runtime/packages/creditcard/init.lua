-- creditcard -- PAN validation, brand detection, formatting, masking.
--
-- Public surface:
--   creditcard.luhn(number)               -> bool
--   creditcard.brand(number)              -> string|nil
--   creditcard.validate(number)           -> { valid, brand, length_valid, luhn_valid }
--   creditcard.format(number, opts?)      -> spaced (or masked) string
--   creditcard.mask(number, opts?)        -> masked string
--   creditcard.generate_test(brand)       -> a valid (industry-test) number
--
-- "number" is a string; spaces and dashes are stripped before processing.

local M = {}

-- ===== Strip non-digits ================================================

local function clean(num)
    if type(num) ~= "string" then num = tostring(num or "") end
    return (num:gsub("[%s%-]", ""))
end

local function only_digits(s)
    return s:match("^%d+$") ~= nil
end

-- ===== Luhn ============================================================

function M.luhn(num)
    num = clean(num)
    if not only_digits(num) or #num < 2 then return false end
    local sum = 0
    local alt = false
    for i = #num, 1, -1 do
        local d = num:byte(i) - 48
        if alt then
            d = d * 2
            if d > 9 then d = d - 9 end
        end
        sum = sum + d
        alt = not alt
    end
    return (sum % 10) == 0
end

-- ===== Brand table =====================================================
--
-- Each rule = { brand, prefix_match_fn, allowed_lengths_table }.
-- prefix_match_fn(num) returns true if the number's prefix matches.

local function prefix_in_range(num, lo, hi, plen)
    local p = num:sub(1, plen)
    if #p < plen then return false end
    local n = tonumber(p)
    if not n then return false end
    return n >= lo and n <= hi
end

local function starts_with(num, prefixes)
    for _, p in ipairs(prefixes) do
        if num:sub(1, #p) == p then return true end
    end
    return false
end

local BRANDS = {
    {
        name = "amex",
        match = function(n) return starts_with(n, { "34", "37" }) end,
        lengths = { 15 },
    },
    {
        name = "visa",
        match = function(n) return n:sub(1, 1) == "4" end,
        lengths = { 13, 16, 19 },
    },
    {
        name = "mastercard",
        match = function(n)
            return starts_with(n, { "51","52","53","54","55" })
                or prefix_in_range(n, 2221, 2720, 4)
        end,
        lengths = { 16 },
    },
    {
        name = "discover",
        match = function(n)
            return n:sub(1, 4) == "6011"
                or n:sub(1, 2) == "65"
                or prefix_in_range(n, 644, 649, 3)
                or prefix_in_range(n, 622126, 622925, 6)
        end,
        lengths = { 16, 17, 18, 19 },
    },
    {
        name = "diners",
        match = function(n)
            return starts_with(n, { "300","301","302","303","304","305","36","38","39" })
        end,
        lengths = { 14, 15, 16, 17, 18, 19 },
    },
    {
        name = "jcb",
        match = function(n)
            return prefix_in_range(n, 3528, 3589, 4)
        end,
        lengths = { 16, 17, 18, 19 },
    },
    {
        name = "unionpay",
        match = function(n)
            return n:sub(1, 2) == "62" or n:sub(1, 2) == "81"
        end,
        lengths = { 16, 17, 18, 19 },
    },
    {
        name = "rupay",
        match = function(n)
            return starts_with(n, { "60","65","81","82","508" })
                and not (n:sub(1, 4) == "6011")  -- discover wins
        end,
        lengths = { 16 },
    },
    {
        name = "maestro",
        match = function(n)
            return starts_with(n, { "50","56","57","58","6" })
        end,
        lengths = { 12, 13, 14, 15, 16, 17, 18, 19 },
    },
}

local function length_valid_for(brand, num)
    for _, b in ipairs(BRANDS) do
        if b.name == brand then
            for _, L in ipairs(b.lengths) do
                if #num == L then return true end
            end
            return false
        end
    end
    return false
end

function M.brand(num)
    num = clean(num)
    if not only_digits(num) then return nil end
    -- The order in BRANDS is significant: more-specific brands first.
    for _, b in ipairs(BRANDS) do
        if b.match(num) then return b.name end
    end
    return nil
end

function M.validate(num)
    local raw = num
    num = clean(num or "")
    local digits_ok = only_digits(num)
    local brand     = digits_ok and M.brand(num) or nil
    local len_ok    = brand and length_valid_for(brand, num) or false
    local luhn_ok   = digits_ok and M.luhn(num) or false
    return {
        valid        = (digits_ok and brand ~= nil and len_ok and luhn_ok),
        brand        = brand,
        length_valid = len_ok,
        luhn_valid   = luhn_ok,
        raw          = raw,
    }
end

-- ===== Formatting & masking ===========================================

local FORMAT_GROUPS = {
    amex      = { 4, 6, 5 },          -- 4-6-5
    diners    = { 4, 6, 4 },          -- 4-6-4 (legacy)
    default   = { 4, 4, 4, 4, 4 },    -- 4-4-4-4 (groups of 4)
}

function M.format(num, opts)
    opts = opts or {}
    num = clean(num)
    if num == "" then return "" end
    local sep = opts.separator or " "
    local brand = M.brand(num) or "default"
    local groups = FORMAT_GROUPS[brand] or FORMAT_GROUPS.default
    local parts, used = {}, 0
    for _, g in ipairs(groups) do
        if used >= #num then break end
        local take = math.min(g, #num - used)
        parts[#parts + 1] = num:sub(used + 1, used + take)
        used = used + take
    end
    if used < #num then
        -- excess digits -> append in groups of 4 to be safe
        local rest = num:sub(used + 1)
        while #rest > 0 do
            parts[#parts + 1] = rest:sub(1, 4)
            rest = rest:sub(5)
        end
    end
    return table.concat(parts, sep)
end

function M.mask(num, opts)
    opts = opts or {}
    local visible_start = opts.visible_start or 0
    local visible_end   = opts.visible_end or 4
    local mask_char     = opts.mask_char or "*"
    num = clean(num)
    if num == "" then return "" end
    if visible_start + visible_end >= #num then
        return num
    end
    local head = num:sub(1, visible_start)
    local tail = num:sub(#num - visible_end + 1)
    local middle = mask_char:rep(#num - visible_start - visible_end)
    local masked = head .. middle .. tail
    if opts.format then
        -- Re-apply spacing on the masked PAN.
        local sep = opts.separator or " "
        local brand = M.brand(num) or "default"
        local groups = FORMAT_GROUPS[brand] or FORMAT_GROUPS.default
        local parts, used = {}, 0
        for _, g in ipairs(groups) do
            if used >= #masked then break end
            local take = math.min(g, #masked - used)
            parts[#parts + 1] = masked:sub(used + 1, used + take)
            used = used + take
        end
        return table.concat(parts, sep)
    end
    return masked
end

-- ===== Test number generator ===========================================
-- Well-known publicly-published industry test numbers. NOT real cards.

local TEST_NUMBERS = {
    visa       = { "4111111111111111", "4012888888881881", "4222222222222" },
    mastercard = { "5555555555554444", "5105105105105100", "2223003122003222" },
    amex       = { "378282246310005", "371449635398431" },
    discover   = { "6011111111111117", "6011000990139424" },
    diners     = { "30569309025904", "38520000023237" },
    jcb        = { "3530111333300000", "3566002020360505" },
    unionpay   = { "6200000000000005" },
    maestro    = { "6759649826438453" },
    rupay      = { "6073849700004947" },
}

function M.generate_test(brand)
    local list = TEST_NUMBERS[brand]
    if not list then return nil end
    return list[1]
end

M.test_numbers = TEST_NUMBERS

return M
