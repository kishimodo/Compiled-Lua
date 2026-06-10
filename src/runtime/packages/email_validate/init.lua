-- email_validate -- email address validation, parsing, normalization.
--
-- Public surface:
--   email_validate.is_valid(email, opts?) -> ok, reason
--     opts:
--       check_mx          -- bool (default false; requires `dns`)
--       check_disposable  -- bool (default true)
--       allow_smtputf8    -- bool (default false; allow non-ASCII local-part)
--   email_validate.parse(email)     -> { local_part, plus_tag, domain } | nil
--   email_validate.normalize(email) -> lowercased, plus-tag stripped (gmail)
--   email_validate.is_disposable(domain) -> bool
--
-- Notes:
--   * Quoted local-parts and IP-literal domains ([1.2.3.4]) are not
--     supported -- callers needing those should bring their own parser.
--   * Full RFC 5322 is intentionally not implemented; this matches what
--     web forms and SMTP MTAs typically accept.

local M = {}

-- Lazy require of dns (so the package still loads without it).
local _dns
local function get_dns()
    if _dns then return _dns end
    local ok, mod = pcall(require, "dns")
    if ok then _dns = mod end
    return _dns
end

-- ===== Disposable provider list =======================================

local DISPOSABLE = {}
for _, d in ipairs({
    "mailinator.com", "10minutemail.com", "guerrillamail.com", "tempmail.com",
    "throwawaymail.com", "yopmail.com", "trashmail.com", "fakeinbox.com",
    "sharklasers.com", "dispostable.com", "spamgourmet.com", "maildrop.cc",
    "getairmail.com", "mintemail.com", "mohmal.com", "tempr.email",
    "tempmailaddress.com", "trbvm.com", "anonbox.net", "spambog.com",
    "tempinbox.com", "incognitomail.com", "33mail.com", "mailcatch.com",
    "deadaddress.com", "discard.email", "emailondeck.com", "fakemailgenerator.com",
    "mvrht.com", "burnermail.io", "tempmailo.com", "harakirimail.com",
    "moakt.cc", "tmpeml.com", "vomoto.com", "wegwerfmail.de", "spam4.me",
    "mailnesia.com", "instantmailbox.com", "tempm.com", "linshiyou.com",
}) do DISPOSABLE[d] = true end

function M.is_disposable(domain)
    if type(domain) ~= "string" then return false end
    return DISPOSABLE[domain:lower()] == true
end

-- ===== Character classes ==============================================

local ATEXT = {}
do
    local s = "abcdefghijklmnopqrstuvwxyz"
                .. "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                .. "0123456789!#$%&'*+-/=?^_`{|}~"
    for i = 1, #s do ATEXT[s:byte(i)] = true end
end

local function is_atext(b) return ATEXT[b] == true end

local function ascii_only(s)
    for i = 1, #s do
        if s:byte(i) > 127 then return false end
    end
    return true
end

-- ===== Local-part check ===============================================

local function valid_local(lp, allow_smtputf8)
    if lp == "" or #lp > 64 then return false, "bad local-part length" end
    if lp:sub(1, 1) == "." or lp:sub(-1) == "." then
        return false, "leading/trailing dot in local-part"
    end
    if lp:find("..", 1, true) then return false, "consecutive dots" end
    for i = 1, #lp do
        local b = lp:byte(i)
        if b == 46 then  -- "."
            -- allowed (we already checked leading/trailing/consecutive)
        elseif is_atext(b) then
            -- ok
        elseif b > 127 then
            if not allow_smtputf8 then
                return false, "non-ASCII in local-part"
            end
        else
            return false, "illegal char in local-part"
        end
    end
    return true
end

-- ===== Domain check ===================================================

local function valid_domain_label(lab)
    if lab == "" or #lab > 63 then return false end
    if lab:sub(1, 1) == "-" or lab:sub(-1) == "-" then return false end
    for i = 1, #lab do
        local b = lab:byte(i)
        local ok = (b >= 48 and b <= 57)        -- 0-9
                or (b >= 65 and b <= 90)        -- A-Z
                or (b >= 97 and b <= 122)       -- a-z
                or b == 45                      -- '-'
                or b > 127                      -- allow UTF-8 byte (IDN)
        if not ok then return false end
    end
    return true
end

local function valid_domain(dom)
    if dom == "" or #dom > 253 then return false, "bad domain length" end
    -- Must have at least one dot (no top-level-only domains for email).
    if not dom:find(".", 1, true) then return false, "missing tld" end
    -- A leading/trailing dot or "" empty label is bad; gmatch("[^.]+") would
    -- silently drop those, so reject them explicitly here.
    if dom:sub(1, 1) == "." or dom:sub(-1) == "." then
        return false, "leading/trailing dot in domain"
    end
    if dom:find("..", 1, true) then return false, "empty domain label" end
    -- Last label (TLD) must contain a letter.
    local labels = {}
    for lab in dom:gmatch("[^.]+") do labels[#labels + 1] = lab end
    if #labels < 2 then return false, "missing tld" end
    for _, lab in ipairs(labels) do
        if not valid_domain_label(lab) then
            return false, "bad domain label: " .. lab
        end
    end
    local tld = labels[#labels]
    if not tld:match("%a") then return false, "tld must contain a letter" end
    return true
end

-- ===== parse / split ==================================================

local function split_at_last(s, sep)
    local i = s:find(sep .. "[^" .. sep .. "]*$")
    if not i then return nil end
    return s:sub(1, i - 1), s:sub(i + 1)
end

function M.parse(email)
    if type(email) ~= "string" or email == "" then return nil end
    local lp, dom = split_at_last(email, "@")
    if not lp or not dom then return nil end
    local local_part, plus_tag = lp, nil
    local plus = lp:find("+", 1, true)
    if plus then
        local_part = lp:sub(1, plus - 1)
        plus_tag   = lp:sub(plus + 1)
    end
    return {
        local_part = local_part,
        plus_tag   = plus_tag,
        domain     = dom,
        full_local = lp,
    }
end

-- ===== normalize ======================================================

local GMAIL_LIKE = {
    ["gmail.com"]      = true,
    ["googlemail.com"] = true,
}

function M.normalize(email)
    local p = M.parse(email)
    if not p then return nil end
    local dom = p.domain:lower()
    local lp  = p.full_local:lower()
    if GMAIL_LIKE[dom] then
        -- Strip dots in local-part and drop "+tag".
        lp = lp:gsub("%.", "")
        local plus = lp:find("+", 1, true)
        if plus then lp = lp:sub(1, plus - 1) end
        if dom == "googlemail.com" then dom = "gmail.com" end
    end
    return lp .. "@" .. dom
end

-- ===== is_valid =======================================================

function M.is_valid(email, opts)
    opts = opts or {}
    local check_disposable = opts.check_disposable
    if check_disposable == nil then check_disposable = true end
    local check_mx = opts.check_mx and true or false
    local allow_smtputf8 = opts.allow_smtputf8 and true or false

    if type(email) ~= "string" or email == "" then
        return false, "empty"
    end
    if #email > 254 then return false, "too long" end
    if not allow_smtputf8 and not ascii_only(email) then
        return false, "non-ASCII without smtputf8"
    end
    local p = M.parse(email)
    if not p then return false, "missing @" end

    local ok, reason = valid_local(p.full_local, allow_smtputf8)
    if not ok then return false, reason end

    ok, reason = valid_domain(p.domain)
    if not ok then return false, reason end

    if check_disposable and M.is_disposable(p.domain) then
        return false, "disposable provider"
    end

    if check_mx then
        local dns = get_dns()
        if not dns then return false, "dns package not available" end
        local mx_ok, _ = pcall(function()
            local recs = dns.resolve(p.domain, "MX")
            if not recs or #recs == 0 then error("no mx") end
        end)
        if not mx_ok then
            -- Some valid domains receive mail on the A record fallback per
            -- RFC 5321 sec 5.1 -- try that before giving up.
            local a_ok = pcall(function()
                local recs = dns.resolve(p.domain, "A")
                if not recs or #recs == 0 then error("no a") end
            end)
            if not a_ok then return false, "no mx/a records" end
        end
    end

    return true
end

return M
