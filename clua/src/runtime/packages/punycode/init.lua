-- punycode -- RFC 3492 IDN encoder / decoder.
--
-- Public surface:
--   punycode.encode(unicode_label)  -> string  (raw punycode, no 'xn--' prefix)
--   punycode.decode(puny_label)     -> string  (UTF-8 result)
--   punycode.to_ascii(domain)       -> string  (handles 'xn--' prefix, dot-split)
--   punycode.to_unicode(domain)     -> string  (UTF-8 result, dot-split)
--
-- The encode/decode pair work on individual labels in code-point space;
-- to_ascii / to_unicode wrap them with UTF-8 conversion and the 'xn--' prefix
-- convention used by full domain names.

local M = {}

-- Bootstring parameters from RFC 3492 section 5.
local BASE         = 36
local TMIN         = 1
local TMAX         = 26
local SKEW         = 38
local DAMP         = 700
local INITIAL_BIAS = 72
local INITIAL_N    = 128
local DELIMITER    = 0x2D  -- '-'

-- digit_to_basic / basic_to_digit per RFC 3492 §5
local function digit_to_basic(d)
    -- 0..25 -> a..z, 26..35 -> 0..9
    if d < 26 then return d + 0x61 end
    return d - 26 + 0x30
end

local function basic_to_digit(cp)
    if cp >= 0x30 and cp <= 0x39 then return cp - 0x30 + 26 end
    if cp >= 0x41 and cp <= 0x5A then return cp - 0x41 end
    if cp >= 0x61 and cp <= 0x7A then return cp - 0x61 end
    return nil
end

local function adapt(delta, numpoints, firsttime)
    if firsttime then
        delta = delta // DAMP
    else
        delta = delta // 2
    end
    delta = delta + (delta // numpoints)
    local k = 0
    while delta > ((BASE - TMIN) * TMAX) // 2 do
        delta = delta // (BASE - TMIN)
        k = k + BASE
    end
    return k + (((BASE - TMIN + 1) * delta) // (delta + SKEW))
end

-- UTF-8 helpers (decode to code points / encode from code points).
local function utf8_to_codepoints(s)
    local cps, n = {}, 0
    local i, len = 1, #s
    while i <= len do
        local b = s:byte(i)
        local cp
        if b < 0x80 then
            cp = b; i = i + 1
        elseif b < 0xC0 then
            error(string.format("punycode: invalid UTF-8 continuation 0x%02X at offset %d", b, i))
        elseif b < 0xE0 then
            local b2 = s:byte(i + 1) or 0
            cp = ((b & 0x1F) << 6) | (b2 & 0x3F)
            i = i + 2
        elseif b < 0xF0 then
            local b2 = s:byte(i + 1) or 0
            local b3 = s:byte(i + 2) or 0
            cp = ((b & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
            i = i + 3
        else
            local b2 = s:byte(i + 1) or 0
            local b3 = s:byte(i + 2) or 0
            local b4 = s:byte(i + 3) or 0
            cp = ((b & 0x07) << 18) | ((b2 & 0x3F) << 12) | ((b3 & 0x3F) << 6) | (b4 & 0x3F)
            i = i + 4
        end
        n = n + 1; cps[n] = cp
    end
    return cps
end

local function codepoints_to_utf8(cps)
    local out, n = {}, 0
    for i = 1, #cps do
        local cp = cps[i]
        if cp < 0x80 then
            n = n + 1; out[n] = string.char(cp)
        elseif cp < 0x800 then
            n = n + 1; out[n] = string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
        elseif cp < 0x10000 then
            n = n + 1; out[n] = string.char(
                0xE0 | (cp >> 12),
                0x80 | ((cp >> 6) & 0x3F),
                0x80 | (cp & 0x3F))
        else
            n = n + 1; out[n] = string.char(
                0xF0 | (cp >> 18),
                0x80 | ((cp >> 12) & 0x3F),
                0x80 | ((cp >> 6) & 0x3F),
                0x80 | (cp & 0x3F))
        end
    end
    return table.concat(out)
end

function M.encode(input)
    if type(input) ~= "string" then
        error("punycode.encode: expected string, got " .. type(input))
    end
    local cps = utf8_to_codepoints(input)
    local n_input = #cps
    local n = INITIAL_N
    local delta = 0
    local bias = INITIAL_BIAS
    local out, oi = {}, 0
    -- Emit basic code points in order.
    local basic_count = 0
    for _, cp in ipairs(cps) do
        if cp < 0x80 then
            basic_count = basic_count + 1
            oi = oi + 1; out[oi] = string.char(cp)
        end
    end
    local h = basic_count
    -- RFC 3492 §6.3: emit the delimiter after the basic code points whenever
    -- there is at least one basic code point (b > 0), independent of whether
    -- any non-basic code points follow. The all-ASCII case ("hello") must
    -- therefore round-trip as "hello-": the decoder uses the LAST delimiter to
    -- separate the literal basic prefix from the (possibly empty) digit suffix.
    if basic_count > 0 then
        oi = oi + 1; out[oi] = "-"
    end
    while h < n_input do
        -- Find the smallest code point >= n in cps.
        local m = math.maxinteger
        for _, cp in ipairs(cps) do
            if cp >= n and cp < m then m = cp end
        end
        delta = delta + (m - n) * (h + 1)
        n = m
        for _, cp in ipairs(cps) do
            if cp < n then
                delta = delta + 1
            elseif cp == n then
                local q = delta
                local k = BASE
                while true do
                    local t
                    if k <= bias then t = TMIN
                    elseif k >= bias + TMAX then t = TMAX
                    else t = k - bias end
                    if q < t then break end
                    oi = oi + 1; out[oi] = string.char(digit_to_basic(t + ((q - t) % (BASE - t))))
                    q = (q - t) // (BASE - t)
                    k = k + BASE
                end
                oi = oi + 1; out[oi] = string.char(digit_to_basic(q))
                bias = adapt(delta, h + 1, h == basic_count)
                delta = 0
                h = h + 1
            end
        end
        delta = delta + 1
        n = n + 1
    end
    return table.concat(out)
end

function M.decode(input)
    if type(input) ~= "string" then
        error("punycode.decode: expected string, got " .. type(input))
    end
    local n = INITIAL_N
    local i = 0
    local bias = INITIAL_BIAS
    local output = {}

    -- Locate the last delimiter, if any. Everything before is verbatim basic.
    local last_delim = 0
    for k = #input, 1, -1 do
        if input:byte(k) == DELIMITER then last_delim = k; break end
    end
    if last_delim > 0 then
        for k = 1, last_delim - 1 do
            local b = input:byte(k)
            if b >= 0x80 then
                error("punycode.decode: non-basic code point in literal portion")
            end
            output[#output + 1] = b
        end
    end

    local pos = (last_delim > 0) and (last_delim + 1) or 1
    while pos <= #input do
        local oldi = i
        local w = 1
        local k = BASE
        while true do
            if pos > #input then
                error("punycode.decode: truncated input")
            end
            local digit = basic_to_digit(input:byte(pos))
            if digit == nil then
                error(string.format("punycode.decode: invalid digit 0x%02X", input:byte(pos)))
            end
            pos = pos + 1
            i = i + digit * w
            local t
            if k <= bias then t = TMIN
            elseif k >= bias + TMAX then t = TMAX
            else t = k - bias end
            if digit < t then break end
            w = w * (BASE - t)
            k = k + BASE
        end
        bias = adapt(i - oldi, #output + 1, oldi == 0)
        n = n + i // (#output + 1)
        i = i % (#output + 1)
        table.insert(output, i + 1, n)
        i = i + 1
    end
    return codepoints_to_utf8(output)
end

function M.to_ascii(domain)
    if type(domain) ~= "string" then
        error("punycode.to_ascii: expected string, got " .. type(domain))
    end
    local out = {}
    for label in domain:gmatch("[^.]+") do
        local needs_encoding = false
        for i = 1, #label do
            if label:byte(i) >= 0x80 then needs_encoding = true; break end
        end
        if needs_encoding then
            out[#out + 1] = "xn--" .. M.encode(label)
        else
            out[#out + 1] = label
        end
    end
    return table.concat(out, ".")
end

function M.to_unicode(domain)
    if type(domain) ~= "string" then
        error("punycode.to_unicode: expected string, got " .. type(domain))
    end
    local out = {}
    for label in domain:gmatch("[^.]+") do
        if label:sub(1, 4):lower() == "xn--" then
            out[#out + 1] = M.decode(label:sub(5))
        else
            out[#out + 1] = label
        end
    end
    return table.concat(out, ".")
end

return M
