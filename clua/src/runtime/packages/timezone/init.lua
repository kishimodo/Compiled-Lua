-- timezone -- IANA-style timezone object with DST-aware offset/name lookup.
--
-- Public surface:
--   timezone.get(name)             -> tz
--   timezone.list()                -> array of known IANA names
--   timezone.local_zone()          -> tz for the system zone
--   timezone.to_zone(t, name)      -> datetime in that display zone
--   timezone.from_zone(t, name)    -> datetime read as if originally that zone
--
-- tz:
--   tz.name              -- IANA identifier (e.g. "America/New_York")
--   tz:offset_at(t)      -> seconds east of UTC at the given epoch/datetime
--   tz:is_dst(t)         -> bool (true if DST is in effect)
--   tz:name_at(t)        -> short zone name (e.g. "EDT" / "EST")
--
-- Implementation:
--   - A small curated set of zones is hard-coded with simple rules:
--     fixed offset, optional Mon/Day/Week DST rule (start/end), and
--     short name pair (std/dst). Covers UTC + the common Americas,
--     Europe, Asia, Australia zones requested by the spec.
--   - For the system's local zone we also probe Win32
--     GetDynamicTimeZoneInformation + GetTimeZoneInformationForYear so
--     we honor the OS-installed dynamic DST rules even if the IANA name
--     isn't in our bundled table.
--   - All offsets are computed against a UTC epoch. is_dst() returns
--     true if the offset at `t` exceeds the zone's standard offset.

require "windows"
local time = require "time"

ffi.cdef[[
typedef struct _DYNAMIC_TIME_ZONE_INFORMATION {
    LONG  Bias;
    unsigned short StandardName[32];
    SYSTEMTIME StandardDate;
    LONG  StandardBias;
    unsigned short DaylightName[32];
    SYSTEMTIME DaylightDate;
    LONG  DaylightBias;
    unsigned short TimeZoneKeyName[128];
    BYTE  DynamicDaylightTimeDisabled;
} DYNAMIC_TIME_ZONE_INFORMATION;

DWORD GetDynamicTimeZoneInformation(DYNAMIC_TIME_ZONE_INFORMATION *);
DWORD GetTimeZoneInformationForYear(USHORT, DYNAMIC_TIME_ZONE_INFORMATION *,
                                    TIME_ZONE_INFORMATION *);
BOOL  SystemTimeToTzSpecificLocalTimeEx(const DYNAMIC_TIME_ZONE_INFORMATION *,
                                        const SYSTEMTIME *, SYSTEMTIME *);
BOOL  SystemTimeToTzSpecificLocalTime(const TIME_ZONE_INFORMATION *,
                                      const SYSTEMTIME *, SYSTEMTIME *);
]]

local C = ffi.C
local floor = math.floor

local M = {}

-- ===== Tz rule engine =================================================
--
-- A "static" zone definition is:
--   {
--     std_offset_hours,             -- offset when DST is NOT in effect
--     dst_offset_hours,             -- offset when DST IS in effect (or nil for none)
--     std_name, dst_name,
--     dst_start = { month, week, weekday, hour }, -- "second Sunday of March at 02:00"
--     dst_end   = { month, week, weekday, hour },
--   }
--
-- week: 1..5 means "Nth occurrence in month" (5 = last).
-- weekday: 0=Sun..6=Sat (Win32 convention).
--
-- For zones with no DST, dst_offset and dst_start/end are nil.

local function nth_weekday_of_month(y, mo, week, weekday)
    -- Compute the (week)th occurrence of `weekday` in (y, mo).
    -- If week == 5 and there's no 5th occurrence, fall back to the
    -- last occurrence in that month.
    local first_day_serial = time._days_from_civil(y, mo, 1)
    local first_wday = time._weekday_from_days(first_day_serial)
    local delta = (weekday - first_wday) % 7
    local day = 1 + delta + (week - 1) * 7
    local dim = time.days_in_month(y, mo)
    if day > dim then
        day = day - 7
    end
    return day
end

local function dst_window_epoch(rule, year)
    -- Return the UTC epoch at which the rule fires for that year, given
    -- that the rule is expressed in *local standard* time.
    local day = nth_weekday_of_month(year, rule.month, rule.week, rule.weekday)
    return time._ymdhms_to_epoch(year, rule.month, day, rule.hour, 0, 0, 0)
end

local function in_dst_static(def, epoch)
    if not def.dst_offset_hours then return false end
    -- Approximate the year of `epoch` using the standard offset.
    local local_epoch = epoch + def.std_offset_hours * 3600
    local y = time._epoch_to_ymdhms(local_epoch)
    -- The rule times are expressed in local standard time, so convert
    -- the trigger instant to UTC by subtracting the std offset.
    local std_off = def.std_offset_hours * 3600
    local dst_off = def.dst_offset_hours * 3600
    local start_local = dst_window_epoch(def.dst_start, y)
    local end_local   = dst_window_epoch(def.dst_end,   y)
    local start_utc = start_local - std_off
    local end_utc   = end_local   - dst_off
    if start_local <= end_local then
        -- Northern-hemisphere style: spring forward, fall back same year.
        return epoch >= start_utc and epoch < end_utc
    else
        -- Southern-hemisphere: DST wraps through January.
        return epoch >= start_utc or epoch < end_utc
    end
end

local function offset_static(def, epoch)
    if def.dst_offset_hours and in_dst_static(def, epoch) then
        return def.dst_offset_hours * 3600
    end
    return def.std_offset_hours * 3600
end

local function name_static(def, epoch)
    if def.dst_offset_hours and in_dst_static(def, epoch) then
        return def.dst_name
    end
    return def.std_name
end

-- ===== Bundled zone table =============================================

local US_DST = {
    -- 2007+: starts 2nd Sunday of March 02:00, ends 1st Sunday of Nov 02:00.
    dst_start = { month = 3,  week = 2, weekday = 0, hour = 2 },
    dst_end   = { month = 11, week = 1, weekday = 0, hour = 2 },
}

local EU_DST = {
    -- Starts last Sunday of March 01:00 UTC, ends last Sunday of Oct 01:00 UTC.
    -- We express in local std time; the conversion to UTC happens in
    -- in_dst_static() via std_offset.
    dst_start = { month = 3,  week = 5, weekday = 0, hour = 2 },
    dst_end   = { month = 10, week = 5, weekday = 0, hour = 3 },
}

local AU_DST = {
    -- Eastern Australia: starts 1st Sunday of October, ends 1st Sunday of April.
    dst_start = { month = 10, week = 1, weekday = 0, hour = 2 },
    dst_end   = { month = 4,  week = 1, weekday = 0, hour = 3 },
}

local ZONES = {
    ["UTC"] = { name = "UTC", std_offset_hours = 0, std_name = "UTC" },
    ["Etc/UTC"] = { name = "Etc/UTC", std_offset_hours = 0, std_name = "UTC" },
    ["Etc/GMT"] = { name = "Etc/GMT", std_offset_hours = 0, std_name = "GMT" },

    ["America/New_York"] = {
        name = "America/New_York", std_offset_hours = -5, dst_offset_hours = -4,
        std_name = "EST", dst_name = "EDT",
        dst_start = US_DST.dst_start, dst_end = US_DST.dst_end,
    },
    ["America/Chicago"] = {
        name = "America/Chicago", std_offset_hours = -6, dst_offset_hours = -5,
        std_name = "CST", dst_name = "CDT",
        dst_start = US_DST.dst_start, dst_end = US_DST.dst_end,
    },
    ["America/Denver"] = {
        name = "America/Denver", std_offset_hours = -7, dst_offset_hours = -6,
        std_name = "MST", dst_name = "MDT",
        dst_start = US_DST.dst_start, dst_end = US_DST.dst_end,
    },
    ["America/Los_Angeles"] = {
        name = "America/Los_Angeles", std_offset_hours = -8, dst_offset_hours = -7,
        std_name = "PST", dst_name = "PDT",
        dst_start = US_DST.dst_start, dst_end = US_DST.dst_end,
    },
    ["America/Phoenix"] = {
        name = "America/Phoenix", std_offset_hours = -7, std_name = "MST",
    },
    ["America/Anchorage"] = {
        name = "America/Anchorage", std_offset_hours = -9, dst_offset_hours = -8,
        std_name = "AKST", dst_name = "AKDT",
        dst_start = US_DST.dst_start, dst_end = US_DST.dst_end,
    },
    ["America/Toronto"] = {
        name = "America/Toronto", std_offset_hours = -5, dst_offset_hours = -4,
        std_name = "EST", dst_name = "EDT",
        dst_start = US_DST.dst_start, dst_end = US_DST.dst_end,
    },
    ["America/Vancouver"] = {
        name = "America/Vancouver", std_offset_hours = -8, dst_offset_hours = -7,
        std_name = "PST", dst_name = "PDT",
        dst_start = US_DST.dst_start, dst_end = US_DST.dst_end,
    },
    ["America/Sao_Paulo"] = {
        name = "America/Sao_Paulo", std_offset_hours = -3, std_name = "BRT",
    },
    ["America/Mexico_City"] = {
        name = "America/Mexico_City", std_offset_hours = -6, std_name = "CST",
    },

    ["Europe/London"] = {
        name = "Europe/London", std_offset_hours = 0, dst_offset_hours = 1,
        std_name = "GMT", dst_name = "BST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Dublin"] = {
        name = "Europe/Dublin", std_offset_hours = 0, dst_offset_hours = 1,
        std_name = "GMT", dst_name = "IST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Paris"] = {
        name = "Europe/Paris", std_offset_hours = 1, dst_offset_hours = 2,
        std_name = "CET", dst_name = "CEST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Berlin"] = {
        name = "Europe/Berlin", std_offset_hours = 1, dst_offset_hours = 2,
        std_name = "CET", dst_name = "CEST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Madrid"] = {
        name = "Europe/Madrid", std_offset_hours = 1, dst_offset_hours = 2,
        std_name = "CET", dst_name = "CEST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Rome"] = {
        name = "Europe/Rome", std_offset_hours = 1, dst_offset_hours = 2,
        std_name = "CET", dst_name = "CEST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Amsterdam"] = {
        name = "Europe/Amsterdam", std_offset_hours = 1, dst_offset_hours = 2,
        std_name = "CET", dst_name = "CEST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Stockholm"] = {
        name = "Europe/Stockholm", std_offset_hours = 1, dst_offset_hours = 2,
        std_name = "CET", dst_name = "CEST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Athens"] = {
        name = "Europe/Athens", std_offset_hours = 2, dst_offset_hours = 3,
        std_name = "EET", dst_name = "EEST",
        dst_start = EU_DST.dst_start, dst_end = EU_DST.dst_end,
    },
    ["Europe/Moscow"] = {
        name = "Europe/Moscow", std_offset_hours = 3, std_name = "MSK",
    },
    ["Europe/Istanbul"] = {
        name = "Europe/Istanbul", std_offset_hours = 3, std_name = "TRT",
    },

    ["Asia/Tokyo"]      = { name = "Asia/Tokyo",      std_offset_hours = 9,  std_name = "JST" },
    ["Asia/Shanghai"]   = { name = "Asia/Shanghai",   std_offset_hours = 8,  std_name = "CST" },
    ["Asia/Hong_Kong"]  = { name = "Asia/Hong_Kong",  std_offset_hours = 8,  std_name = "HKT" },
    ["Asia/Singapore"]  = { name = "Asia/Singapore",  std_offset_hours = 8,  std_name = "SGT" },
    ["Asia/Seoul"]      = { name = "Asia/Seoul",      std_offset_hours = 9,  std_name = "KST" },
    ["Asia/Kolkata"]    = { name = "Asia/Kolkata",    std_offset_hours = 5.5, std_name = "IST" },
    ["Asia/Dubai"]      = { name = "Asia/Dubai",      std_offset_hours = 4,  std_name = "GST" },
    ["Asia/Jerusalem"]  = { name = "Asia/Jerusalem",  std_offset_hours = 2,  std_name = "IST" },
    ["Asia/Bangkok"]    = { name = "Asia/Bangkok",    std_offset_hours = 7,  std_name = "ICT" },
    ["Asia/Jakarta"]    = { name = "Asia/Jakarta",    std_offset_hours = 7,  std_name = "WIB" },

    ["Australia/Sydney"] = {
        name = "Australia/Sydney", std_offset_hours = 10, dst_offset_hours = 11,
        std_name = "AEST", dst_name = "AEDT",
        dst_start = AU_DST.dst_start, dst_end = AU_DST.dst_end,
    },
    ["Australia/Melbourne"] = {
        name = "Australia/Melbourne", std_offset_hours = 10, dst_offset_hours = 11,
        std_name = "AEST", dst_name = "AEDT",
        dst_start = AU_DST.dst_start, dst_end = AU_DST.dst_end,
    },
    ["Australia/Perth"]    = { name = "Australia/Perth",    std_offset_hours = 8,  std_name = "AWST" },
    ["Australia/Brisbane"] = { name = "Australia/Brisbane", std_offset_hours = 10, std_name = "AEST" },
    ["Pacific/Auckland"] = {
        name = "Pacific/Auckland", std_offset_hours = 12, dst_offset_hours = 13,
        std_name = "NZST", dst_name = "NZDT",
        -- NZ DST: last Sunday of September -> first Sunday of April.
        dst_start = { month = 9, week = 5, weekday = 0, hour = 2 },
        dst_end   = { month = 4, week = 1, weekday = 0, hour = 3 },
    },

    ["Africa/Johannesburg"] = { name = "Africa/Johannesburg", std_offset_hours = 2, std_name = "SAST" },
    ["Africa/Cairo"]        = { name = "Africa/Cairo",        std_offset_hours = 2, std_name = "EET"  },
    ["Africa/Lagos"]        = { name = "Africa/Lagos",        std_offset_hours = 1, std_name = "WAT"  },
}

-- ===== Tz object ======================================================

local Tz = {}
Tz.__index = Tz

function Tz:offset_at(t)
    local epoch
    if type(t) == "number" then epoch = t
    elseif type(t) == "table" and t._is_datetime then epoch = t:epoch()
    else error("tz:offset_at expects datetime or epoch number") end
    if self.win32_ then
        return self:_win32_offset(epoch)
    end
    return offset_static(self.def_, epoch)
end

function Tz:is_dst(t)
    local epoch
    if type(t) == "number" then epoch = t
    elseif type(t) == "table" and t._is_datetime then epoch = t:epoch()
    else error("tz:is_dst expects datetime or epoch number") end
    if self.win32_ then
        return self:_win32_offset(epoch) ~= self.win32_std_offset_
    end
    return self.def_.dst_offset_hours ~= nil and in_dst_static(self.def_, epoch)
end

function Tz:name_at(t)
    local epoch
    if type(t) == "number" then epoch = t
    elseif type(t) == "table" and t._is_datetime then epoch = t:epoch()
    else error("tz:name_at expects datetime or epoch number") end
    if self.win32_ then
        return self:_win32_offset(epoch) ~= self.win32_std_offset_
            and (self.win32_dst_name_ or "DST")
            or  (self.win32_std_name_ or self.name)
    end
    return name_static(self.def_, epoch)
end

function Tz:__tostring() return "timezone(" .. self.name .. ")" end

-- ===== Win32 fallback for the system zone =============================

local DTZI = ffi.new("DYNAMIC_TIME_ZONE_INFORMATION")
local TZI  = ffi.new("TIME_ZONE_INFORMATION")

local function utf16_to_string(wbuf, max_chars)
    -- Find NUL terminator (or stop at max_chars).
    local out = {}
    for i = 0, max_chars - 1 do
        local w = wbuf[i]
        if w == 0 then break end
        if w < 128 then out[#out + 1] = string.char(w) end
    end
    return table.concat(out)
end

local function dtzi_offset_at(self, epoch)
    -- For an arbitrary epoch we re-query year-specific TZI and walk it.
    local y = time._epoch_to_ymdhms(epoch)
    local rc = C.GetTimeZoneInformationForYear(y, DTZI, TZI)
    if rc == 0xFFFFFFFF then
        return self.win32_std_offset_
    end
    -- If no DST configured for that year (zero StandardDate.wMonth), it's std.
    if TZI.DaylightDate.wMonth == 0 or TZI.StandardDate.wMonth == 0 then
        return -(TZI.Bias + TZI.StandardBias) * 60
    end
    -- Build local rules from TZI and check.
    local dst_start = {
        month   = TZI.DaylightDate.wMonth,
        week    = TZI.DaylightDate.wDay,
        weekday = TZI.DaylightDate.wDayOfWeek,
        hour    = TZI.DaylightDate.wHour,
    }
    local dst_end = {
        month   = TZI.StandardDate.wMonth,
        week    = TZI.StandardDate.wDay,
        weekday = TZI.StandardDate.wDayOfWeek,
        hour    = TZI.StandardDate.wHour,
    }
    local std_off = -(TZI.Bias + TZI.StandardBias) * 60
    local dst_off = -(TZI.Bias + TZI.DaylightBias) * 60
    -- Translate the rule windows to UTC.
    local start_local = time._ymdhms_to_epoch(y, dst_start.month,
        nth_weekday_of_month(y, dst_start.month, dst_start.week, dst_start.weekday),
        dst_start.hour, 0, 0, 0)
    local end_local = time._ymdhms_to_epoch(y, dst_end.month,
        nth_weekday_of_month(y, dst_end.month, dst_end.week, dst_end.weekday),
        dst_end.hour, 0, 0, 0)
    local start_utc = start_local - std_off
    local end_utc   = end_local   - dst_off
    local in_dst
    if start_local <= end_local then
        in_dst = epoch >= start_utc and epoch < end_utc
    else
        in_dst = epoch >= start_utc or epoch < end_utc
    end
    return in_dst and dst_off or std_off
end

Tz._win32_offset = dtzi_offset_at

local function build_local_zone()
    local rc = C.GetDynamicTimeZoneInformation(DTZI)
    if rc == 0xFFFFFFFF then
        -- Fall back to UTC.
        return setmetatable({
            name = "UTC", def_ = ZONES["UTC"],
        }, Tz)
    end
    local key = utf16_to_string(DTZI.TimeZoneKeyName, 128)
    local std = utf16_to_string(DTZI.StandardName,    32)
    local dst = utf16_to_string(DTZI.DaylightName,    32)
    local std_off = -(DTZI.Bias + DTZI.StandardBias) * 60
    return setmetatable({
        name              = key ~= "" and key or "Local",
        win32_            = true,
        win32_std_offset_ = std_off,
        win32_std_name_   = std ~= "" and std or nil,
        win32_dst_name_   = dst ~= "" and dst or nil,
    }, Tz)
end

-- ===== Public API =====================================================

local _local_zone

function M.local_zone()
    if not _local_zone then _local_zone = build_local_zone() end
    return _local_zone
end

function M.get(name)
    if name == nil then return M.local_zone() end
    if name == "local" then return M.local_zone() end
    local def = ZONES[name]
    if def then
        return setmetatable({ name = def.name, def_ = def }, Tz)
    end
    -- Numeric "UTC+N" / "UTC-N" forms.
    local sign, hh, mm = name:match("^UTC?([%+%-])(%d?%d?):?(%d?%d?)$")
    if sign then
        local off = (tonumber(hh) or 0) * 3600 + (tonumber(mm) or 0) * 60
        if sign == "-" then off = -off end
        return setmetatable({
            name = name,
            def_ = { name = name, std_offset_hours = off / 3600, std_name = name },
        }, Tz)
    end
    error("timezone.get: unknown zone " .. tostring(name))
end

function M.list()
    local out = {}
    for k in pairs(ZONES) do out[#out + 1] = k end
    table.sort(out)
    return out
end

function M.to_zone(t, name)
    local tz = M.get(name)
    local epoch = type(t) == "number" and t or t:epoch()
    return time.from_epoch(epoch, tz:offset_at(epoch))
end

function M.from_zone(t, name)
    -- Interpret the local fields of `t` as if they were already in `name`.
    -- Returns a datetime whose epoch corresponds to that wallclock in
    -- the requested zone.
    local tz = M.get(name)
    local epoch
    if type(t) == "number" then
        epoch = t
    else
        -- Use the components of t to build the wallclock, then subtract
        -- the zone offset at that point.
        local y, mo, d, h, mi, s, ms = time._epoch_to_ymdhms(t:epoch() + t.tz_offset_)
        local wall = time._ymdhms_to_epoch(y, mo, d, h, mi, s, ms)
        local off  = tz:offset_at(wall)
        epoch = wall - off
    end
    return time.from_epoch(epoch, tz:offset_at(epoch))
end

M.Tz = Tz

return M
