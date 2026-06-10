-- cron -- cron expression parser + next/prev/matches/iter.
--
-- Public surface:
--   cron.parse(expr, opts?)         -> cron (opts = { seconds=false, year=false })
--   cron.is_valid(expr, opts?)      -> bool, err?
--   cron.describe(expr, opts?)      -> human-readable description string
--
-- cron methods:
--   cron:next(from?)                -> datetime (next strict-after `from`)
--   cron:prev(from?)                -> datetime (last fire at-or-before `from`)
--   cron:matches(t)                 -> bool
--   cron:iter(from?)                -> stateful iterator yielding datetimes
--
-- Supported tokens (per field):
--   *           any value
--   N           literal
--   N-M         inclusive range
--   N-M/S       step within range
--   */S         step across full range
--   N,M,...     list
--   L           last day-of-month (dom), or last weekday of month (dow)
--   ND L        last N-day of month (dow), e.g. "5L" = last Friday
--   ND W        nearest weekday (dom), e.g. "15W"
--   N#K         Kth occurrence of N-day in month (dow), e.g. "1#2" = 2nd Monday
--   ?           ignore (dom or dow only, Quartz-style)
--
-- Aliases:
--   @hourly @daily @midnight @weekly @monthly @yearly @annually @reboot
--
-- Field counts:
--   5: m h dom mon dow                              (default)
--   6: s m h dom mon dow                            (opts.seconds = true)
--   7: s m h dom mon dow year                       (opts.seconds + opts.year)
--   6: m h dom mon dow year                         (opts.year alone)
--
-- All datetime arithmetic is done in UTC; pass tz-shifted datetimes if
-- you need zone-local semantics.

local time = require "time"

local M = {}

-- ===== Tokenisation ===================================================

local MONTH_NAMES = {
    jan=1, feb=2, mar=3, apr=4, may=5, jun=6,
    jul=7, aug=8, sep=9, oct=10, nov=11, dec=12,
}
local DOW_NAMES = {
    sun=0, mon=1, tue=2, wed=3, thu=4, fri=5, sat=6,
}

local ALIAS = {
    ["@yearly"]   = "0 0 1 1 *",
    ["@annually"] = "0 0 1 1 *",
    ["@monthly"]  = "0 0 1 * *",
    ["@weekly"]   = "0 0 * * 0",
    ["@daily"]    = "0 0 * * *",
    ["@midnight"] = "0 0 * * *",
    ["@hourly"]   = "0 * * * *",
}

-- Field metadata: { min, max, name, allow_names? }.
local FIELDS = {
    second = { 0, 59, "second" },
    minute = { 0, 59, "minute" },
    hour   = { 0, 23, "hour" },
    dom    = { 1, 31, "day-of-month" },
    month  = { 1, 12, "month",       names = MONTH_NAMES },
    dow    = { 0, 6,  "day-of-week", names = DOW_NAMES },
    year   = { 1970, 2099, "year" },
}

-- A parsed field is one of:
--   { kind="set",  values=set, raw=string }              -- a bitset of allowed values
--   { kind="L",    raw=string }                          -- L alone (dom)
--   { kind="LDOW", dow=N, raw=string }                   -- "5L" last Friday
--   { kind="W",    day=N, raw=string }                   -- "15W"
--   { kind="HASH", dow=N, nth=K, raw=string }            -- "1#2"
--   { kind="ANY",  raw=string }                          -- '?' (treat as wildcard)

local function err(field, msg) return nil, "cron field '" .. field .. "': " .. msg end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function lookup_name(field_key, token)
    local meta = FIELDS[field_key]
    local names = meta.names
    if names then
        local v = names[token:lower():sub(1, 3)]
        if v then return v end
    end
    return tonumber(token)
end

local function parse_simple_value(field_key, token)
    -- Resolves a single number-or-name to an int, or returns nil.
    local v = lookup_name(field_key, token)
    return v
end

local function add_range(set, lo, hi, step, min_v, max_v)
    if lo < min_v or hi > max_v then return false, "value out of range" end
    if step <= 0 then return false, "step must be > 0" end
    if lo > hi then return false, "range descending" end
    for v = lo, hi, step do set[v] = true end
    return true
end

local function parse_field(field_key, raw)
    local meta = FIELDS[field_key]
    local min_v, max_v = meta[1], meta[2]
    raw = trim(raw)
    if raw == "" then return err(field_key, "empty") end

    -- '?' means "ignore", only sensible for dom or dow.
    if raw == "?" then
        if field_key ~= "dom" and field_key ~= "dow" then
            return err(field_key, "'?' only allowed in dom or dow")
        end
        return { kind = "ANY", raw = raw }
    end

    if field_key == "dom" and raw:upper() == "L" then
        return { kind = "L", raw = raw }
    end
    if field_key == "dow" then
        local nL = raw:match("^(%w+)[Ll]$")
        if nL then
            local v = parse_simple_value("dow", nL)
            if not v or v < 0 or v > 6 then return err(field_key, "bad LDOW: " .. raw) end
            return { kind = "LDOW", dow = v, raw = raw }
        end
        local d, k = raw:match("^(%w+)#(%d+)$")
        if d then
            local v = parse_simple_value("dow", d)
            local nth = tonumber(k)
            if not v or v < 0 or v > 6 then return err(field_key, "bad HASH dow: " .. raw) end
            if not nth or nth < 1 or nth > 5 then return err(field_key, "bad HASH nth: " .. raw) end
            return { kind = "HASH", dow = v, nth = nth, raw = raw }
        end
    end
    if field_key == "dom" then
        local nW = raw:match("^(%d+)[Ww]$")
        if nW then
            local n = tonumber(nW)
            if not n or n < 1 or n > 31 then return err(field_key, "bad W: " .. raw) end
            return { kind = "W", day = n, raw = raw }
        end
    end

    local set = {}
    for part in raw:gmatch("[^,]+") do
        part = trim(part)
        local body, step_str = part:match("^(.-)/(.+)$")
        local step = 1
        if body then
            step = tonumber(step_str)
            if not step then return err(field_key, "bad step: " .. step_str) end
        else
            body = part
        end
        if body == "*" then
            local ok, e = add_range(set, min_v, max_v, step, min_v, max_v)
            if not ok then return err(field_key, e) end
        else
            local lo_s, hi_s = body:match("^([^-]+)%-([^-]+)$")
            if lo_s then
                local lo = parse_simple_value(field_key, lo_s)
                local hi = parse_simple_value(field_key, hi_s)
                if not lo or not hi then return err(field_key, "bad range: " .. body) end
                local ok, e = add_range(set, lo, hi, step, min_v, max_v)
                if not ok then return err(field_key, e) end
            else
                local v = parse_simple_value(field_key, body)
                if not v then return err(field_key, "bad value: " .. body) end
                -- Accept dow == 7 as Sunday for the classic Sun=0,Sun=7 convention.
                if field_key == "dow" and v == 7 then v = 0 end
                if v < min_v or v > max_v then return err(field_key, "out of range: " .. body) end
                if step ~= 1 then
                    local ok, e = add_range(set, v, max_v, step, min_v, max_v)
                    if not ok then return err(field_key, e) end
                else
                    set[v] = true
                end
            end
        end
    end
    return { kind = "set", values = set, raw = raw }
end

-- ===== Parse + describe ===============================================

local function field_layout(opts)
    -- Returns the ordered list of field keys for the chosen layout.
    if opts.seconds and opts.year then
        return { "second", "minute", "hour", "dom", "month", "dow", "year" }
    elseif opts.seconds then
        return { "second", "minute", "hour", "dom", "month", "dow" }
    elseif opts.year then
        return { "minute", "hour", "dom", "month", "dow", "year" }
    end
    return { "minute", "hour", "dom", "month", "dow" }
end

local Cron = {}
Cron.__index = Cron

function M.parse(expr, opts)
    if type(expr) ~= "string" then return nil, "expr must be string" end
    opts = opts or {}
    local s = trim(expr):lower()
    local reboot = false
    if ALIAS[s] then
        s = ALIAS[s]
        opts = { seconds = false, year = false }
    elseif s == "@reboot" then
        reboot = true
    end

    if reboot then
        return setmetatable({
            reboot_ = true,
            opts_   = { seconds = false, year = false },
            expr_   = "@reboot",
            born_   = time.now(),
        }, Cron)
    end

    local layout = field_layout(opts)
    local fields = {}
    local idx = 1
    for tok in s:gmatch("%S+") do
        fields[#fields + 1] = tok
    end
    if #fields ~= #layout then
        return nil, string.format(
            "expected %d fields, got %d (expr=%q)", #layout, #fields, expr)
    end
    local parsed = {}
    for i, key in ipairs(layout) do
        local f, e = parse_field(key, fields[i])
        if not f then return nil, e end
        parsed[key] = f
    end
    return setmetatable({
        fields_ = parsed,
        layout_ = layout,
        opts_   = { seconds = opts.seconds == true, year = opts.year == true },
        expr_   = expr,
    }, Cron)
end

function M.is_valid(expr, opts)
    local c, e = M.parse(expr, opts)
    if c then return true end
    return false, e
end

local function describe_set(field, max_v)
    if field.kind == "ANY" then return "any" end
    if field.kind == "L" then return "last day" end
    if field.kind == "LDOW" then return "last weekday=" .. field.dow end
    if field.kind == "W" then return "nearest weekday to " .. field.day end
    if field.kind == "HASH" then return "the " .. field.nth .. "th weekday=" .. field.dow end
    -- "set"
    local count = 0
    local lo, hi
    for v = 0, max_v do
        if field.values[v] then
            count = count + 1
            if not lo then lo = v end
            hi = v
        end
    end
    if count == max_v + 1 then return "every" end
    if count == 1 then return "at " .. lo end
    return "set " .. field.raw
end

function M.describe(expr, opts)
    local c, e = M.parse(expr, opts)
    if not c then return nil, e end
    if c.reboot_ then return "at startup" end
    local parts = {}
    for _, key in ipairs(c.layout_) do
        parts[#parts + 1] = key .. "=" .. describe_set(c.fields_[key], FIELDS[key][2])
    end
    return table.concat(parts, ", ")
end

-- ===== Match / next / prev ============================================

local function field_min_of(field, lo, hi)
    -- Return the smallest value in [lo, hi] that matches `field`, or nil.
    if field.kind == "ANY" then return lo end
    if field.kind == "set" then
        for v = lo, hi do if field.values[v] then return v end end
        return nil
    end
    return nil
end

local function field_contains(field, v, ctx)
    -- ctx provides (y, mo) so L/W/HASH can resolve.
    if field.kind == "ANY" then return true end
    if field.kind == "set" then return field.values[v] == true end
    if field.kind == "L" then
        return v == time.days_in_month(ctx.y, ctx.mo)
    end
    if field.kind == "LDOW" then
        -- v is the day-of-month; check that it's the last weekday=dow.
        local dim = time.days_in_month(ctx.y, ctx.mo)
        if v ~= field.dow_day_in_month then return false end
        return true
    end
    if field.kind == "W" then
        return v == field.resolved_day
    end
    if field.kind == "HASH" then
        return v == field.resolved_day
    end
    return false
end

local function dow_of(y, mo, d)
    return time._weekday_from_days(time._days_from_civil(y, mo, d))
end

local function resolve_special_dom(field, y, mo)
    if field.kind == "L" then
        return { [time.days_in_month(y, mo)] = true }
    end
    if field.kind == "W" then
        local target = field.day
        local dim = time.days_in_month(y, mo)
        if target > dim then target = dim end
        local wd = dow_of(y, mo, target)
        if wd == 0 then -- Sunday
            target = target + 1
            if target > dim then target = target - 2 end
        elseif wd == 6 then -- Saturday
            target = target - 1
            if target < 1 then target = target + 2 end
        end
        return { [target] = true }
    end
    if field.kind == "ANY" then return "ANY" end
    if field.kind == "set" then
        local out = {}
        for v in pairs(field.values) do
            if v <= time.days_in_month(y, mo) then out[v] = true end
        end
        return out
    end
    return {}
end

local function resolve_special_dow(field, y, mo)
    if field.kind == "ANY" then return "ANY" end
    if field.kind == "LDOW" then
        -- The last occurrence of weekday `dow` in (y, mo).
        local dim = time.days_in_month(y, mo)
        for d = dim, dim - 6, -1 do
            if dow_of(y, mo, d) == field.dow then
                return { [d] = true }
            end
        end
        return {}
    end
    if field.kind == "HASH" then
        -- The nth occurrence of weekday `dow` in (y, mo).
        local dim = time.days_in_month(y, mo)
        local count = 0
        for d = 1, dim do
            if dow_of(y, mo, d) == field.dow then
                count = count + 1
                if count == field.nth then return { [d] = true } end
            end
        end
        return {}
    end
    if field.kind == "set" then
        -- Translate dow set into the set of days in (y, mo) matching those weekdays.
        local out = {}
        local dim = time.days_in_month(y, mo)
        for d = 1, dim do
            if field.values[dow_of(y, mo, d)] then out[d] = true end
        end
        return out
    end
    return {}
end

local function day_matches(c, y, mo, d)
    local dom = c.fields_.dom
    local dow = c.fields_.dow
    local dom_set = resolve_special_dom(dom, y, mo)
    local dow_set = resolve_special_dow(dow, y, mo)
    local dom_match, dow_match
    if dom_set == "ANY" then dom_match = true else dom_match = dom_set[d] == true end
    if dow_set == "ANY" then dow_match = true else dow_match = dow_set[d] == true end
    -- Classic Vixie cron: if both dom and dow are restricted (neither "*"
    -- nor "?"), the field is matched if EITHER matches. If only one is
    -- restricted, only that one is required.
    local dom_restricted = not (dom.kind == "ANY" or
        (dom.kind == "set" and dom.raw == "*"))
    local dow_restricted = not (dow.kind == "ANY" or
        (dow.kind == "set" and dow.raw == "*"))
    if dom_restricted and dow_restricted then
        return dom_match or dow_match
    elseif dom_restricted then
        return dom_match
    elseif dow_restricted then
        return dow_match
    else
        return true
    end
end

local function time_matches(c, h, mi, s)
    local hf = c.fields_.hour
    local mf = c.fields_.minute
    local sf = c.opts_.seconds and c.fields_.second
    if hf.kind == "set" and not hf.values[h] then return false end
    if mf.kind == "set" and not mf.values[mi] then return false end
    if sf and sf.kind == "set" and not sf.values[s] then return false end
    return true
end

function Cron:matches(t)
    if self.reboot_ then return false end
    local epoch = type(t) == "number" and t or t:epoch()
    local y, mo, d, h, mi, s = time._epoch_to_ymdhms(epoch)
    if self.opts_.year then
        local yf = self.fields_.year
        if yf.kind == "set" and not yf.values[y] then return false end
    end
    local mof = self.fields_.month
    if mof.kind == "set" and not mof.values[mo] then return false end
    if not day_matches(self, y, mo, d) then return false end
    return time_matches(self, h, mi, s)
end

-- next() walks the components from coarsest (year/month) inward,
-- bumping to the next valid combination on any mismatch.
local function search_forward(c, y, mo, d, h, mi, s, step_seconds)
    local step = step_seconds or 60
    -- Walk forward in seconds (or minutes) until we find a match,
    -- with a safety cap (year+10) so a bad expression doesn't loop forever.
    local max_y = c.opts_.year and 2099 or (y + 20)
    while true do
        if y > max_y then return nil end
        local mof = c.fields_.month
        if mof.kind == "set" and not mof.values[mo] then
            mo = mo + 1; d = 1; h = 0; mi = 0; s = 0
            if mo > 12 then mo = 1; y = y + 1 end
        elseif not day_matches(c, y, mo, d) then
            d = d + 1; h = 0; mi = 0; s = 0
            local dim = time.days_in_month(y, mo)
            if d > dim then
                d = 1; mo = mo + 1
                if mo > 12 then mo = 1; y = y + 1 end
            end
        elseif not time_matches(c, h, mi, s) then
            if step >= 60 then
                mi = mi + 1; s = 0
                if mi > 59 then mi = 0; h = h + 1 end
            else
                s = s + 1
                if s > 59 then s = 0; mi = mi + 1 end
                if mi > 59 then mi = 0; h = h + 1 end
            end
            if h > 23 then h = 0; d = d + 1
                if d > time.days_in_month(y, mo) then
                    d = 1; mo = mo + 1
                    if mo > 12 then mo = 1; y = y + 1 end
                end
            end
        else
            if c.opts_.year then
                local yf = c.fields_.year
                if yf.kind == "set" and not yf.values[y] then
                    y = y + 1; mo = 1; d = 1; h = 0; mi = 0; s = 0
                    -- Fast-forward to a valid year if any exist.
                    while y <= max_y and not yf.values[y] do y = y + 1 end
                else
                    return y, mo, d, h, mi, s
                end
            else
                return y, mo, d, h, mi, s
            end
        end
    end
end

local function search_backward(c, y, mo, d, h, mi, s, step_seconds)
    local step = step_seconds or 60
    local min_y = c.opts_.year and 1970 or (y - 20)
    while true do
        if y < min_y then return nil end
        local mof = c.fields_.month
        if mof.kind == "set" and not mof.values[mo] then
            mo = mo - 1; h = 23; mi = 59; s = 59
            if mo < 1 then mo = 12; y = y - 1 end
            d = time.days_in_month(y, mo)
        elseif not day_matches(c, y, mo, d) then
            d = d - 1; h = 23; mi = 59; s = 59
            if d < 1 then
                mo = mo - 1
                if mo < 1 then mo = 12; y = y - 1 end
                d = time.days_in_month(y, mo)
            end
        elseif not time_matches(c, h, mi, s) then
            if step >= 60 then
                mi = mi - 1; s = 59
                if mi < 0 then mi = 59; h = h - 1 end
            else
                s = s - 1
                if s < 0 then s = 59; mi = mi - 1 end
                if mi < 0 then mi = 59; h = h - 1 end
            end
            if h < 0 then h = 23; d = d - 1
                if d < 1 then
                    mo = mo - 1
                    if mo < 1 then mo = 12; y = y - 1 end
                    d = time.days_in_month(y, mo)
                end
            end
        else
            if c.opts_.year then
                local yf = c.fields_.year
                if yf.kind == "set" and not yf.values[y] then
                    y = y - 1; mo = 12; d = time.days_in_month(y, mo)
                    h = 23; mi = 59; s = 59
                else
                    return y, mo, d, h, mi, s
                end
            else
                return y, mo, d, h, mi, s
            end
        end
    end
end

function Cron:next(from)
    if self.reboot_ then return nil end
    local epoch
    if from == nil then
        epoch = time.now()
    elseif type(from) == "number" then
        epoch = from
    else
        epoch = from:epoch()
    end
    -- Advance one second past `from`.
    epoch = math.floor(epoch) + (self.opts_.seconds and 1 or 60 - (math.floor(epoch) % 60))
    local y, mo, d, h, mi, s = time._epoch_to_ymdhms(epoch)
    if not self.opts_.seconds then s = 0 end
    y, mo, d, h, mi, s = search_forward(self, y, mo, d, h, mi, s,
                                        self.opts_.seconds and 1 or 60)
    if not y then return nil end
    if not self.opts_.seconds then s = 0 end
    return time.datetime(y, mo, d, h, mi, s, 0, 0)
end

function Cron:prev(from)
    if self.reboot_ then return nil end
    local epoch
    if from == nil then
        epoch = time.now()
    elseif type(from) == "number" then
        epoch = from
    else
        epoch = from:epoch()
    end
    epoch = math.floor(epoch) - (self.opts_.seconds and 1 or 60 - (math.floor(epoch) % 60) + 1)
    if epoch < 0 then return nil end
    local y, mo, d, h, mi, s = time._epoch_to_ymdhms(epoch)
    if not self.opts_.seconds then s = 0 end
    y, mo, d, h, mi, s = search_backward(self, y, mo, d, h, mi, s,
                                         self.opts_.seconds and 1 or 60)
    if not y then return nil end
    if not self.opts_.seconds then s = 0 end
    return time.datetime(y, mo, d, h, mi, s, 0, 0)
end

function Cron:iter(from)
    local cur = from
    return function()
        local nxt = self:next(cur)
        if not nxt then return nil end
        cur = nxt
        return nxt
    end
end

function Cron:__tostring() return "cron(" .. self.expr_ .. ")" end

M.Cron = Cron

return M
