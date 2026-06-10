-- cron_expr -- standalone cron expression parser and evaluator.
--
-- Public surface (low-level):
--   cron_expr.parse(expr)            -> evaluator, err
--   evaluator:matches(epoch)         -> bool
--   evaluator:next_after(epoch)      -> epoch
--
-- Public surface (analysis / UI):
--   cron_expr.validate(expr)         -> ok, err
--   cron_expr.describe(expr)         -> "Every Monday at 5am" (or nil, err)
--   cron_expr.simplify(expr)         -> canonical_expr (or nil, err)
--   cron_expr.fields(expr)           -> { sec?, minute, hour, dom, month, dow } (per-field sorted int lists)
--   cron_expr.is_subset(a, b)        -> bool          (does every match of a also match b?)
--   cron_expr.union(a, b)            -> { ... }       (set-style: per-field union, fallback nil if either uses struct rules)
--   cron_expr.intersection(a, b)     -> { ... }       (per-field intersection)
--
-- Supported syntax:
--   * 5 fields:  minute hour dom mon dow
--   * 6 fields:  second minute hour dom mon dow
--   * tokens:    *, value, value-value, list,of,values, */step, start-end/step
--   * dom only:  L (last day of month), 15W (nearest weekday)
--   * dow only:  L (last weekday of month -- treat as last), 5L (last Friday),
--                MON#2 (second Monday)
--   * named:     @yearly @annually @monthly @weekly @daily @midnight @hourly
--   * names:     JAN..DEC for months, SUN..SAT for days
--
-- Notes on semantics:
--   * Day-of-week uses 0..6 where 0=Sunday. 7 also accepted as Sunday.
--   * When both dom and dow are restricted (neither '*'), a match occurs on
--     either -- this is Vixie-cron / crontab(5) compatible behaviour.
--   * next_after returns the smallest epoch >= base+1 second that matches.
--   * All time math goes through os.time/os.date in *local* time -- if you
--     need UTC, call os.date("!*t", t) and feed those fields yourself.

local M = {}

local floor = math.floor
local huge  = math.huge

local MONTHS = {
    JAN=1, FEB=2, MAR=3, APR=4, MAY=5, JUN=6,
    JUL=7, AUG=8, SEP=9, OCT=10, NOV=11, DEC=12,
}
local DOWS = {
    SUN=0, MON=1, TUE=2, WED=3, THU=4, FRI=5, SAT=6,
}

local NAMED = {
    ["@yearly"]   = "0 0 1 1 *",
    ["@annually"] = "0 0 1 1 *",
    ["@monthly"]  = "0 0 1 * *",
    ["@weekly"]   = "0 0 * * 0",
    ["@daily"]    = "0 0 * * *",
    ["@midnight"] = "0 0 * * *",
    ["@hourly"]   = "0 * * * *",
}

-- ===== Calendar helpers =================================================

local function is_leap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function days_in_month(y, m)
    if m == 2 and is_leap(y) then return 29 end
    return DAYS_IN_MONTH[m]
end

local function dow_of(y, m, d)
    -- wday from os.date is 1..7 (Sun..Sat) -- convert to 0..6 (Sun..Sat).
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    return os.date("*t", t).wday - 1
end

-- ===== Field parser =====================================================
--
-- For each field we parse the textual form into a *set* of integers covering
-- the allowed range, plus a small bag of "structured" predicates for the
-- special L / W / # forms that can't be expanded to plain integers ahead of
-- time (they depend on the year/month being tested).

local function set_add(set, lo, hi, step)
    for v = lo, hi, step do set[v] = true end
end

-- range checking utilities; produce nil + error string on bad input
local function fail(msg) return nil, msg end

-- Forward decl so parse_field can call it; body defined further down.
local parse_range

-- Resolve symbolic name -> integer, or nil if not a name.
local function resolve_name(tok, field)
    local u = tok:upper()
    if field == "mon" then return MONTHS[u] end
    if field == "dow" then return DOWS[u] end
    return nil
end

local function parse_int(tok, field)
    local n = resolve_name(tok, field)
    if n then return n end
    n = tonumber(tok)
    if n == nil or n ~= floor(n) then return nil end
    return n
end

local function parse_field(text, lo, hi, field)
    -- Returns { set = { ... }, struct = { ... } } or nil, err.
    local out = { set = {}, struct = {}, raw = text, star = false }

    if text == "*" then
        for v = lo, hi do out.set[v] = true end
        out.star = true
        return out
    end

    -- Split commas.
    for part in (text .. ","):gmatch("([^,]+),") do
        part = part:gsub("%s+", "")
        if part == "" then return fail("empty field part") end

        -- Specials first: L, dW, dL, NAME#N, dom 'L'.
        if field == "dom" then
            -- L = last day of month
            if part == "L" then
                out.struct[#out.struct + 1] = { kind = "last_dom" }
            elseif part:match("^(%d+)W$") then
                local d = tonumber(part:match("^(%d+)W$"))
                if d < 1 or d > 31 then return fail("dom W out of range: " .. d) end
                out.struct[#out.struct + 1] = { kind = "nearest_weekday", day = d }
            else
                local ok, err = parse_range(part, lo, hi, field, out)
                if not ok then return nil, err end
            end
        elseif field == "dow" then
            -- L alone -> Saturday last? Vixie reads bare L as 'last day of month'
            -- but inside dow it commonly means 7 (Saturday) in some impls or
            -- "last X". To stay strict, accept only N L forms here.
            local d, rest = part:match("^(%d)L$"), part:match("^L$")
            local m_nth = part:match("^(%a+)#(%d+)$") or part:match("^(%d+)#(%d+)$")
            if d then
                local n = tonumber(d)
                if n < 0 or n > 7 then return fail("dow L out of range") end
                if n == 7 then n = 0 end
                out.struct[#out.struct + 1] = { kind = "last_dow", dow = n }
            elseif rest then
                -- bare L in dow -> last day of month, dow-position
                out.struct[#out.struct + 1] = { kind = "last_dom" }
            elseif part:find("#", 1, true) then
                local namepart, npart = part:match("^([^#]+)#(%d+)$")
                if not namepart then return fail("bad #N syntax: " .. part) end
                local n = parse_int(namepart, "dow")
                local k = tonumber(npart)
                if n == nil then return fail("bad dow in #N: " .. namepart) end
                if n < 0 or n > 7 then return fail("dow out of range") end
                if n == 7 then n = 0 end
                if k < 1 or k > 5 then return fail("#N out of range (1..5)") end
                out.struct[#out.struct + 1] = { kind = "nth_dow", dow = n, nth = k }
            else
                local ok, err = parse_range(part, lo, hi, field, out)
                if not ok then return nil, err end
            end
        else
            local ok, err = parse_range(part, lo, hi, field, out)
            if not ok then return nil, err end
        end
    end

    -- Sunday=7 normalization in dow.
    if field == "dow" and out.set[7] then
        out.set[7] = nil
        out.set[0] = true
    end

    return out
end

-- Body for the forward-declared parse_range.
parse_range = function(part, lo, hi, field, out)
    -- Handle /step.
    local step = 1
    local body = part
    local slash = part:find("/", 1, true)
    if slash then
        body = part:sub(1, slash - 1)
        step = tonumber(part:sub(slash + 1))
        if not step or step < 1 then return fail("bad step: " .. part) end
    end

    local start, finish
    if body == "*" then
        start, finish = lo, hi
    elseif body:find("-", 1, true) then
        local a, b = body:match("^(.-)-(.+)$")
        start = parse_int(a, field)
        finish = parse_int(b, field)
        if start == nil or finish == nil then return fail("bad range: " .. body) end
    else
        start = parse_int(body, field)
        if start == nil then return fail("bad value: " .. body) end
        if slash then
            -- N/step means N, N+step, ... up to hi (cron extension).
            finish = hi
        else
            finish = start
        end
    end

    if field == "dow" then
        if start == 7 then start = 0 end
        if finish == 7 then finish = 0 end
    end

    if start < lo or start > hi or finish < lo or finish > hi then
        return fail("out of range " .. lo .. ".." .. hi .. ": " .. body)
    end

    if start <= finish then
        set_add(out.set, start, finish, step)
    else
        -- Wrap-around range, e.g. 22-2 (hours).
        set_add(out.set, start, hi, step)
        set_add(out.set, lo, finish, step)
    end

    return true
end

-- ===== Whole-expression parser ==========================================

local function tokenize(expr)
    local tokens = {}
    for tok in expr:gmatch("%S+") do tokens[#tokens + 1] = tok end
    return tokens
end

local function check_field(name, field_spec, value)
    -- field_spec is the table returned by parse_field. value is the integer
    -- being tested. Plain set membership is the common case.
    if field_spec.set[value] then return true end
    if #field_spec.struct == 0 then return false end
    return false  -- structured predicates handled at the match() layer
end

-- ===== Evaluator object =================================================

local Eval = {}
Eval.__index = Eval

local function struct_dom_match(struct_list, y, m, d)
    for _, s in ipairs(struct_list) do
        if s.kind == "last_dom" then
            if d == days_in_month(y, m) then return true end
        elseif s.kind == "nearest_weekday" then
            local target = s.day
            if target > days_in_month(y, m) then target = days_in_month(y, m) end
            -- The "nearest weekday" rule: if target falls on Sat, jump back
            -- to Fri unless that crosses the month boundary, in which case
            -- jump forward to Mon. Mirror behaviour for Sun.
            local dow = dow_of(y, m, target)
            local resolved = target
            if dow == 6 then  -- Sat
                if target > 1 then resolved = target - 1 else resolved = target + 2 end
            elseif dow == 0 then  -- Sun
                if target < days_in_month(y, m) then resolved = target + 1 else resolved = target - 2 end
            end
            if d == resolved then return true end
        end
    end
    return false
end

local function struct_dow_match(struct_list, y, m, d)
    for _, s in ipairs(struct_list) do
        if s.kind == "last_dow" then
            local target_dow = s.dow
            -- Last `target_dow` of the month.
            local last = days_in_month(y, m)
            local last_dow = dow_of(y, m, last)
            local diff = (last_dow - target_dow) % 7
            if d == (last - diff) then return true end
        elseif s.kind == "last_dom" then
            if d == days_in_month(y, m) then return true end
        elseif s.kind == "nth_dow" then
            -- The Nth occurrence of dow in month: first occurrence is on day
            -- 1 + ((target - dow_of_first) mod 7); add 7*(nth-1).
            local first_dow = dow_of(y, m, 1)
            local first_occ = 1 + ((s.dow - first_dow) % 7)
            local day_n = first_occ + 7 * (s.nth - 1)
            if day_n <= days_in_month(y, m) and d == day_n then return true end
        end
    end
    return false
end

function Eval:matches(epoch)
    local t = os.date("*t", epoch)
    local y, mo, d, h, mi, se = t.year, t.month, t.day, t.hour, t.min, t.sec
    local wday = t.wday - 1  -- 0..6, Sun..Sat

    -- Plain numeric fields first; cheap rejects come first.
    if not self.sec.set[se] then return false end
    if not self.min.set[mi] then return false end
    if not self.hour.set[h] then return false end
    if not self.mon.set[mo] then return false end

    -- DOM / DOW interaction:
    --   * both star -> any day matches
    --   * one star  -> only the other restricts
    --   * neither   -> OR them (Vixie semantics)
    local dom_ok = self.dom.set[d] or struct_dom_match(self.dom.struct, y, mo, d)
    local dow_ok = self.dow.set[wday] or struct_dow_match(self.dow.struct, y, mo, d)

    if self.dom.star and self.dow.star then
        return true
    elseif self.dom.star then
        return dow_ok
    elseif self.dow.star then
        return dom_ok
    else
        return dom_ok or dow_ok
    end
end

function Eval:next_after(epoch)
    -- Brute-but-bounded search: start at epoch+1s and advance minute-by-minute
    -- (or second-by-second if seconds field is non-trivial). Cap at five years
    -- to detect impossible expressions (e.g. Feb 30) without an infinite loop.
    local step = (self.has_seconds and not self.sec.star) and 1 or 60
    -- If seconds is "0" (the canonical case) we can step by 60s as long as
    -- we land on second=0; align first.
    local t = epoch + 1
    if step == 60 then
        local mod = t % 60
        if mod ~= 0 then t = t + (60 - mod) end
    end
    -- 5 years of seconds is the upper bound for any sane periodic schedule.
    local limit = epoch + 5 * 366 * 86400
    while t <= limit do
        if self:matches(t) then return t end
        -- Optimization: if month doesn't match, jump to the 1st of the next
        -- matching month at 00:00:00.
        local tab = os.date("*t", t)
        if not self.mon.set[tab.month] then
            tab.day = 1; tab.hour = 0; tab.min = 0; tab.sec = 0
            tab.month = tab.month + 1
            if tab.month > 12 then tab.month = 1; tab.year = tab.year + 1 end
            t = os.time(tab)
        else
            t = t + step
        end
    end
    return nil, "no match within 5 years"
end

-- ===== Top-level parse ==================================================

function M.parse(expr)
    if type(expr) ~= "string" then return nil, "expression must be a string" end
    expr = expr:gsub("^%s+", ""):gsub("%s+$", "")

    -- Named shortcut?
    local named = NAMED[expr:lower()]
    if named then expr = named end

    local tokens = tokenize(expr)
    local has_seconds
    if #tokens == 5 then
        has_seconds = false
    elseif #tokens == 6 then
        has_seconds = true
    else
        return nil, "expected 5 or 6 fields, got " .. #tokens
    end

    local idx = 1
    local function take() local v = tokens[idx]; idx = idx + 1; return v end

    local sec_field
    if has_seconds then
        local s, err = parse_field(take(), 0, 59, "sec")
        if not s then return nil, "sec: " .. err end
        sec_field = s
    else
        sec_field = { set = { [0] = true }, struct = {}, raw = "0", star = false }
    end

    local min, err1 = parse_field(take(), 0, 59, "min")
    if not min then return nil, "min: " .. err1 end
    local hour, err2 = parse_field(take(), 0, 23, "hour")
    if not hour then return nil, "hour: " .. err2 end
    local dom, err3 = parse_field(take(), 1, 31, "dom")
    if not dom then return nil, "dom: " .. err3 end
    local mon, err4 = parse_field(take(), 1, 12, "mon")
    if not mon then return nil, "mon: " .. err4 end
    local dow, err5 = parse_field(take(), 0, 6, "dow")
    if not dow then return nil, "dow: " .. err5 end

    return setmetatable({
        sec = sec_field, min = min, hour = hour, dom = dom, mon = mon, dow = dow,
        has_seconds = has_seconds, raw = expr,
    }, Eval)
end

-- ===== Analysis / UI helpers ============================================

-- Sort a set-shaped table into an ascending integer list.
local function set_to_list(set)
    local out = {}
    for v in pairs(set) do out[#out + 1] = v end
    table.sort(out)
    return out
end

-- Inverse: list back to set.
local function list_to_set(list)
    local out = {}
    for _, v in ipairs(list) do out[v] = true end
    return out
end

function M.validate(expr)
    local p, err = M.parse(expr)
    if not p then return false, err end
    return true
end

function M.fields(expr)
    local p, err = M.parse(expr)
    if not p then return nil, err end
    local out = {
        minute = set_to_list(p.min.set),
        hour   = set_to_list(p.hour.set),
        dom    = set_to_list(p.dom.set),
        month  = set_to_list(p.mon.set),
        dow    = set_to_list(p.dow.set),
    }
    if p.has_seconds then out.sec = set_to_list(p.sec.set) end
    return out
end

-- Try to describe a single field as a human phrase. Falls back to the
-- raw token text when the set doesn't have an obvious shape.
local DOW_NAMES = { [0] = "Sunday", "Monday", "Tuesday", "Wednesday",
                    "Thursday", "Friday", "Saturday" }
local MON_NAMES = { "January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November", "December" }

local function describe_set(list, lo, hi, kind)
    local n = #list
    local full = (hi - lo + 1)
    if n == full then return nil end  -- "every"; caller decides phrasing
    if n == 1 then
        local v = list[1]
        if kind == "dow"   then return DOW_NAMES[v] end
        if kind == "month" then return MON_NAMES[v] end
        return tostring(v)
    end
    -- Detect arithmetic progression (step pattern).
    if n >= 3 then
        local step = list[2] - list[1]
        local is_progression = (list[1] == lo)
        for i = 2, n do
            if list[i] - list[i - 1] ~= step then is_progression = false; break end
        end
        if is_progression and list[n] + step > hi then
            return "every " .. step
        end
    end
    -- Otherwise enumerate.
    local names = {}
    for i, v in ipairs(list) do
        if kind == "dow"   then names[i] = DOW_NAMES[v]
        elseif kind == "month" then names[i] = MON_NAMES[v]
        else names[i] = tostring(v) end
    end
    if n == 2 then return names[1] .. " and " .. names[2] end
    return table.concat(names, ", ", 1, n - 1) .. ", and " .. names[n]
end

local function format_time(h, m, s)
    -- 12h clock with am/pm; if h/m are single values produce a friendly form.
    if s and s ~= 0 then return string.format("%02d:%02d:%02d", h, m, s) end
    if h == 0  and m == 0 then return "midnight" end
    if h == 12 and m == 0 then return "noon" end
    local suffix = h < 12 and "am" or "pm"
    local hh = h % 12; if hh == 0 then hh = 12 end
    if m == 0 then return tostring(hh) .. suffix end
    return string.format("%d:%02d%s", hh, m, suffix)
end

function M.describe(expr)
    local p, err = M.parse(expr)
    if not p then return nil, err end

    local min_list   = set_to_list(p.min.set)
    local hour_list  = set_to_list(p.hour.set)
    local dom_list   = set_to_list(p.dom.set)
    local mon_list   = set_to_list(p.mon.set)
    local dow_list   = set_to_list(p.dow.set)

    -- Time of day phrasing -- handled specially for the common case
    -- of a single (hour, minute) pair which is the most readable.
    local time_phrase
    if #hour_list == 1 and #min_list == 1 then
        time_phrase = "at " .. format_time(hour_list[1], min_list[1])
    elseif #hour_list == 24 and #min_list == 1 then
        time_phrase = "every hour at " .. min_list[1] .. " minutes past"
    elseif #min_list == 60 and #hour_list == 1 then
        time_phrase = "every minute of hour " .. hour_list[1]
    elseif #hour_list == 24 and #min_list == 60 then
        time_phrase = "every minute"
    else
        local hp = describe_set(hour_list, 0, 23, "hour") or "every hour"
        local mp = describe_set(min_list, 0, 59, "minute") or "every minute"
        if hp:sub(1, 5) == "every" then
            time_phrase = mp .. " minute of " .. hp
        else
            time_phrase = "at hour " .. hp .. ", minute " .. mp
        end
    end

    local day_phrase
    if p.dom.star and p.dow.star then
        day_phrase = "every day"
    elseif p.dow.star then
        local dp = describe_set(dom_list, 1, 31, "dom")
        day_phrase = "on day " .. (dp or "every") .. " of the month"
    elseif p.dom.star then
        local dp = describe_set(dow_list, 0, 6, "dow") or "every day"
        day_phrase = "on " .. dp
    else
        local dp1 = describe_set(dom_list, 1, 31, "dom") or "every"
        local dp2 = describe_set(dow_list, 0, 6, "dow") or "every"
        day_phrase = "on day " .. dp1 .. " of the month or on " .. dp2
    end

    local month_phrase
    if p.mon.star or #mon_list == 12 then
        month_phrase = nil
    else
        local mp = describe_set(mon_list, 1, 12, "month")
        month_phrase = "in " .. (mp or "every month")
    end

    local pieces = { time_phrase, day_phrase }
    if month_phrase then pieces[#pieces + 1] = month_phrase end
    return table.concat(pieces, ", ")
end

-- Re-emit each field's set in canonical comma-list form. If the field used
-- structured rules (L/W/#) we can't losslessly canonicalise; keep raw text.
local function canon_field(field, lo, hi)
    if #field.struct > 0 then return field.raw end
    if field.star then return "*" end
    local list = set_to_list(field.set)
    if #list == (hi - lo + 1) then return "*" end
    -- Compress runs and step-progressions.
    local pieces = {}
    local i = 1
    while i <= #list do
        local j = i
        while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
        if j == i then
            pieces[#pieces + 1] = tostring(list[i])
        elseif j == i + 1 then
            pieces[#pieces + 1] = tostring(list[i])
            pieces[#pieces + 1] = tostring(list[j])
        else
            pieces[#pieces + 1] = list[i] .. "-" .. list[j]
        end
        i = j + 1
    end
    return table.concat(pieces, ",")
end

function M.simplify(expr)
    local p, err = M.parse(expr)
    if not p then return nil, err end
    -- Build the parts table with explicit indexed assignment to keep the
    -- bytecode emitter off the "vararg trailing call -> OP_SETLIST" path
    -- which some hosts don't JIT-compile.
    local parts = {}
    if p.has_seconds then
        parts[1] = canon_field(p.sec,  0, 59)
        parts[2] = canon_field(p.min,  0, 59)
        parts[3] = canon_field(p.hour, 0, 23)
        parts[4] = canon_field(p.dom,  1, 31)
        parts[5] = canon_field(p.mon,  1, 12)
        parts[6] = canon_field(p.dow,  0, 6)
    else
        parts[1] = canon_field(p.min,  0, 59)
        parts[2] = canon_field(p.hour, 0, 23)
        parts[3] = canon_field(p.dom,  1, 31)
        parts[4] = canon_field(p.mon,  1, 12)
        parts[5] = canon_field(p.dow,  0, 6)
    end
    return table.concat(parts, " ")
end

-- Subset test on the set-portion only; if either expression uses struct
-- predicates we conservatively decline and return nil.
local function field_struct_present(p)
    return #p.sec.struct > 0 or #p.min.struct > 0 or #p.hour.struct > 0
        or #p.dom.struct > 0 or #p.mon.struct > 0 or #p.dow.struct > 0
end

local function set_is_subset(a_set, b_set)
    for v in pairs(a_set) do if not b_set[v] then return false end end
    return true
end

function M.is_subset(a, b)
    local pa, ea = M.parse(a); if not pa then return nil, ea end
    local pb, eb = M.parse(b); if not pb then return nil, eb end
    if field_struct_present(pa) or field_struct_present(pb) then
        return nil, "cannot reason about structured (L/W/#) rules"
    end
    -- Each field of a must be a subset of the corresponding field of b.
    if not set_is_subset(pa.min.set,  pb.min.set)  then return false end
    if not set_is_subset(pa.hour.set, pb.hour.set) then return false end
    if not set_is_subset(pa.mon.set,  pb.mon.set)  then return false end
    -- DOM/DOW interact (Vixie OR-rule). We conservatively require both
    -- relations to hold so the answer is sound, not necessarily tight.
    if not set_is_subset(pa.dom.set, pb.dom.set) then return false end
    if not set_is_subset(pa.dow.set, pb.dow.set) then return false end
    return true
end

-- Per-field union/intersection. Only meaningful when neither side carries
-- struct predicates; we surface nil + reason if either does.
local function combine(a, b, op)
    local pa, ea = M.parse(a); if not pa then return nil, ea end
    local pb, eb = M.parse(b); if not pb then return nil, eb end
    if field_struct_present(pa) or field_struct_present(pb) then
        return nil, "cannot combine structured (L/W/#) rules"
    end
    local function f(sa, sb, lo, hi)
        local result = {}
        if op == "union" then
            for v in pairs(sa) do result[v] = true end
            for v in pairs(sb) do result[v] = true end
        else  -- intersection
            for v in pairs(sa) do if sb[v] then result[v] = true end end
        end
        local list = set_to_list(result)
        if #list == 0 then return nil end  -- empty intersection
        return canon_field({ set = result, struct = {}, raw = "",
            star = (#list == (hi - lo + 1)) }, lo, hi)
    end
    local mins = f(pa.min.set,  pb.min.set,  0, 59); if not mins then return nil, "empty minute" end
    local hrs  = f(pa.hour.set, pb.hour.set, 0, 23); if not hrs  then return nil, "empty hour" end
    local doms = f(pa.dom.set,  pb.dom.set,  1, 31); if not doms then return nil, "empty dom" end
    local mons = f(pa.mon.set,  pb.mon.set,  1, 12); if not mons then return nil, "empty month" end
    local dows = f(pa.dow.set,  pb.dow.set,  0, 6 ); if not dows then return nil, "empty dow" end
    local parts = {}
    parts[1] = mins; parts[2] = hrs; parts[3] = doms; parts[4] = mons; parts[5] = dows
    return table.concat(parts, " ")
end

function M.union(a, b)        return combine(a, b, "union") end
function M.intersection(a, b) return combine(a, b, "intersection") end

return M
