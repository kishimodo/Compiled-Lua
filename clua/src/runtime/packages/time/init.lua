-- time -- high-precision clocks, calendar math, durations, ISO 8601.
--
-- Clocks:
--   time.now()            -> double, system wallclock (seconds, fractional)
--   time.monotonic()      -> double, monotonic seconds since first call (never goes back)
--   time.monotonic_ns()   -> int64, monotonic nanoseconds
--   time.epoch_ms()       -> int64, system wallclock in milliseconds
--   time.epoch_ns()       -> int64, system wallclock in nanoseconds
--   time.sleep(seconds)
--   time.sleep_until(t_or_epoch)
--
-- Calendar constructors:
--   time.date(year, month, day)                       -> datetime
--   time.time(hour, min, sec, ms?)                    -> datetime (today's date)
--   time.datetime(year, month, day, hour, min, sec, ms?, tz_offset?)
--   time.from_epoch(epoch_seconds, tz_offset?)        -> datetime
--   time.now_dt(tz_offset?)                           -> datetime (system clock)
--
-- ISO 8601:
--   time.parse_iso8601(s)                  -> datetime
--   time.format_iso8601(t, opts?)          -> string
--     opts = { utc=true, fractional=3, with_offset=true }
--
-- Duration:
--   time.duration(hms_string_or_table)
--   d:days() | :hours() | :minutes() | :seconds() | :milliseconds() | :total_ms() | :total_seconds()
--   d:negate()
--   d1 + d2, d1 - d2, -d, d1 == d2, d1 < d2
--
-- Datetime:
--   t.year / t.month / t.day / t.hour / t.minute / t.second / t.millisecond
--   t:weekday()   -- 0=Sunday..6=Saturday
--   t:yearday()
--   t:epoch()     -> seconds (float, UTC)
--   t:epoch_ms()  -> int64
--   t:format(pattern)            -- strftime-style
--   t:to_iso8601(opts?)
--   t:to_utc(), t:to_local(), t:with_offset(seconds)
--   t1 + duration -> datetime
--   t1 - duration -> datetime
--   t1 - t2       -> duration
--   t1 == t2, t1 < t2, t1 <= t2
--
-- Helpers:
--   time.add_days(t, n), time.add_months(t, n), time.add_years(t, n)
--   time.start_of_day(t), time.start_of_month(t), time.start_of_year(t)
--   time.is_leap(year), time.days_in_month(year, month)
--   time.local_offset(epoch?) -> seconds east of UTC at that instant
--
-- Implementation notes:
--   - All datetimes carry a UTC epoch (float seconds) plus an optional
--     tz_offset (seconds east of UTC) used for display only. Arithmetic
--     and equality are based on the underlying epoch, so a UTC datetime
--     compares equal to the same instant expressed in any local zone.
--   - Conversions go through Howard Hinnant's branch-free Gregorian
--     formulas (days_from_civil / civil_from_days).
--   - monotonic() uses QueryPerformanceCounter (origin captured on the
--     first call so a long-running program never loses double precision
--     to the raw 64-bit tick count).

require "windows"

ffi.cdef[[
void GetSystemTimePreciseAsFileTime(FILETIME * lpSystemTimeAsFileTime);
]]

local C       = ffi.C
local FT_t    = ffi.typeof("FILETIME")
local LL1     = ffi.typeof("LONGLONG[1]")
local FT_BUF  = ffi.new(FT_t)
local floor   = math.floor

local M = {}

-- ===== Civil <-> serial day count (proleptic Gregorian) ================

local function days_from_civil(y, m, d)
    y = y - (m <= 2 and 1 or 0)
    local era = floor(y / 400)
    local yoe = y - era * 400
    local mp  = m + (m > 2 and -3 or 9)
    local doy = floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function civil_from_days(z)
    z = z + 719468
    local era = floor(z / 146097)
    local doe = z - era * 146097
    local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
    local y   = yoe + era * 400
    local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
    local mp  = floor((5 * doy + 2) / 153)
    local d   = doy - floor((153 * mp + 2) / 5) + 1
    local m   = mp + (mp < 10 and 3 or -9)
    y = y + (m <= 2 and 1 or 0)
    return y, m, d
end

local function weekday_from_days(z)
    return (z + 4) % 7
end

function M.is_leap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function M.days_in_month(y, m)
    if m == 2 and M.is_leap(y) then return 29 end
    return MONTH_DAYS[m]
end

-- ===== Wallclock + monotonic ==========================================

-- FILETIME ticks at 1970-01-01 (100-ns since 1601). Lua 5.4 integer
-- arithmetic gives us 64-bit signed math directly, so we can stay in
-- pure Lua. FFI cdata arithmetic is unsupported on this runtime.
local FT_TO_UNIX_TICKS = 116444736000000000   -- 100-ns ticks at 1970

local function filetime_to_unix_ns(ft)
    local lo = ft.dwLowDateTime
    local hi = ft.dwHighDateTime
    -- DWORDs come back as Lua integers under the runtime FFI.
    local ticks = (hi << 32) | lo
    if ticks < FT_TO_UNIX_TICKS then return 0 end
    return (ticks - FT_TO_UNIX_TICKS) * 100
end

function M.now()
    C.GetSystemTimePreciseAsFileTime(FT_BUF)
    return filetime_to_unix_ns(FT_BUF) / 1e9
end

function M.epoch_ns()
    C.GetSystemTimePreciseAsFileTime(FT_BUF)
    return filetime_to_unix_ns(FT_BUF)
end

function M.epoch_ms()
    C.GetSystemTimePreciseAsFileTime(FT_BUF)
    return filetime_to_unix_ns(FT_BUF) // 1000000
end

local _qpc_freq, _qpc_origin
local QPC1 = ffi.new(LL1)

local function qpc_now()
    C.QueryPerformanceCounter(QPC1)
    return QPC1[0]
end

local function ensure_qpc()
    if _qpc_freq then return end
    C.QueryPerformanceFrequency(QPC1)
    _qpc_freq   = QPC1[0]
    _qpc_origin = qpc_now()
end

function M.monotonic()
    ensure_qpc()
    local delta = qpc_now() - _qpc_origin
    return tonumber(delta) / tonumber(_qpc_freq)
end

function M.monotonic_ns()
    ensure_qpc()
    local delta = tonumber(qpc_now() - _qpc_origin)
    local freq  = tonumber(_qpc_freq)
    -- Split into seconds + remainder so the product stays in int64.
    local secs = delta // freq
    local rem  = delta -  secs * freq
    return secs * 1000000000 + (rem * 1000000000) // freq
end

function M.sleep(seconds)
    if not seconds or seconds <= 0 then return end
    local whole_ms = floor(seconds * 1000)
    if whole_ms > 1 then
        C.Sleep(whole_ms - 1)
    end
    ensure_qpc()
    local target = seconds * tonumber(_qpc_freq)
    local start  = qpc_now()
    while tonumber(qpc_now() - start) < target do end
end

function M.sleep_until(t)
    local target_epoch
    if type(t) == "number" then
        target_epoch = t
    elseif type(t) == "table" and t._is_datetime then
        target_epoch = t.epoch_
    else
        error("sleep_until: expected number epoch or datetime")
    end
    local delta = target_epoch - M.now()
    if delta > 0 then M.sleep(delta) end
end

-- ===== Local TZ offset via Win32 ======================================

ffi.cdef[[
typedef struct _TIME_ZONE_INFORMATION {
    LONG       Bias;
    unsigned short StandardName[32];
    SYSTEMTIME StandardDate;
    LONG       StandardBias;
    unsigned short DaylightName[32];
    SYSTEMTIME DaylightDate;
    LONG       DaylightBias;
} TIME_ZONE_INFORMATION;
DWORD GetTimeZoneInformation(TIME_ZONE_INFORMATION *);
BOOL  SystemTimeToFileTime(const SYSTEMTIME *, FILETIME *);
BOOL  FileTimeToSystemTime(const FILETIME *, SYSTEMTIME *);
BOOL  SystemTimeToTzSpecificLocalTime(const TIME_ZONE_INFORMATION *,
                                      const SYSTEMTIME *, SYSTEMTIME *);
]]

local TZI_BUF = ffi.new("TIME_ZONE_INFORMATION")
local ST_BUF  = ffi.new("SYSTEMTIME")
local ST_BUF2 = ffi.new("SYSTEMTIME")

local function epoch_to_ymdhms(epoch)
    local secs = floor(epoch)
    local frac = epoch - secs
    local ms   = floor(frac * 1000 + 0.5)
    if ms >= 1000 then secs = secs + 1; ms = ms - 1000 end
    local days = floor(secs / 86400)
    local rem  = secs - days * 86400
    local y, mo, d = civil_from_days(days)
    local h  = floor(rem / 3600)
    rem = rem - h * 3600
    local mi = floor(rem / 60)
    local s  = rem - mi * 60
    return y, mo, d, h, mi, s, ms
end

local function ymdhms_to_epoch(y, mo, d, h, mi, s, ms)
    local days = days_from_civil(y, mo, d)
    return days * 86400 + h * 3600 + mi * 60 + s + (ms or 0) / 1000
end

function M.local_offset(epoch)
    epoch = epoch or M.now()
    local y, mo, d, h, mi, s, ms = epoch_to_ymdhms(epoch)
    ST_BUF.wYear = y; ST_BUF.wMonth = mo; ST_BUF.wDayOfWeek = 0
    ST_BUF.wDay = d;  ST_BUF.wHour  = h;  ST_BUF.wMinute = mi
    ST_BUF.wSecond = s; ST_BUF.wMilliseconds = ms
    local rc = C.GetTimeZoneInformation(TZI_BUF)
    if rc == 0xFFFFFFFF then return 0 end
    if C.SystemTimeToTzSpecificLocalTime(TZI_BUF, ST_BUF, ST_BUF2) == 0 then
        return 0
    end
    local local_epoch = ymdhms_to_epoch(
        ST_BUF2.wYear, ST_BUF2.wMonth, ST_BUF2.wDay,
        ST_BUF2.wHour, ST_BUF2.wMinute, ST_BUF2.wSecond,
        ST_BUF2.wMilliseconds)
    -- TZ offsets are always multiples of 60 seconds in practice; round
    -- to integer to avoid float fuzz from the float-epoch round-trip.
    return floor(local_epoch - epoch + 0.5)
end

-- ===== Duration =======================================================

local Duration = {}
Duration.__index = Duration

local function new_duration(ms)
    -- ms is a number (possibly negative, possibly fractional from sub-ms).
    return setmetatable({ _is_duration = true, ms_ = ms }, Duration)
end

function Duration:total_ms()      return self.ms_ end
function Duration:total_seconds() return self.ms_ / 1000 end
function Duration:milliseconds()  return self.ms_ end
function Duration:seconds()       return self.ms_ / 1000 end
function Duration:minutes()       return self.ms_ / 60000 end
function Duration:hours()         return self.ms_ / 3600000 end
function Duration:days()          return self.ms_ / 86400000 end
function Duration:negate()        return new_duration(-self.ms_) end

function Duration.__add(a, b)
    if getmetatable(a) == Duration and getmetatable(b) == Duration then
        return new_duration(a.ms_ + b.ms_)
    end
    error("duration: can only add duration + duration")
end

function Duration.__sub(a, b)
    if getmetatable(a) == Duration and getmetatable(b) == Duration then
        return new_duration(a.ms_ - b.ms_)
    end
    error("duration: can only subtract duration - duration")
end

function Duration.__unm(a) return new_duration(-a.ms_) end

function Duration.__eq(a, b)
    return getmetatable(a) == Duration and getmetatable(b) == Duration
       and a.ms_ == b.ms_
end

function Duration.__lt(a, b) return a.ms_ < b.ms_ end
function Duration.__le(a, b) return a.ms_ <= b.ms_ end

function Duration:__tostring()
    local ms = self.ms_
    if ms == 0 then return "0s" end
    local neg = ms < 0
    if neg then ms = -ms end
    local d  = floor(ms / 86400000); ms = ms - d * 86400000
    local h  = floor(ms / 3600000);  ms = ms - h * 3600000
    local mi = floor(ms / 60000);    ms = ms - mi * 60000
    local s  = floor(ms / 1000);     ms = ms - s * 1000
    local out = {}
    if d > 0   then out[#out + 1] = d  .. "d"  end
    if h > 0   then out[#out + 1] = h  .. "h"  end
    if mi > 0  then out[#out + 1] = mi .. "m"  end
    if s > 0   then out[#out + 1] = s  .. "s"  end
    if ms > 0  then out[#out + 1] = ms .. "ms" end
    if #out == 0 then out[#out + 1] = "0s" end
    local r = table.concat(out)
    return neg and ("-" .. r) or r
end

local DURATION_UNIT_MS = {
    ns = 1e-6, us = 1e-3, ms = 1,
    s = 1000, sec = 1000, secs = 1000, second = 1000, seconds = 1000,
    m = 60000, min = 60000, mins = 60000, minute = 60000, minutes = 60000,
    h = 3600000, hr = 3600000, hrs = 3600000, hour = 3600000, hours = 3600000,
    d = 86400000, day = 86400000, days = 86400000,
    w = 604800000, wk = 604800000, week = 604800000, weeks = 604800000,
}

local function parse_duration_string(s)
    s = s:gsub("%s+", "")
    if s == "" then return nil, "empty duration" end
    local total_ms = 0
    local i, n = 1, #s
    if s:sub(1, 1) == "-" then i = 2 end
    local neg = s:sub(1, 1) == "-"
    while i <= n do
        local num_start = i
        local b = s:byte(i)
        while b and ((b >= 0x30 and b <= 0x39) or b == 0x2E) do
            i = i + 1; b = s:byte(i)
        end
        if i == num_start then return nil, "expected number at " .. i end
        local num = tonumber(s:sub(num_start, i - 1))
        if not num then return nil, "bad number" end
        local u_start = i
        while b and ((b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A)) do
            i = i + 1; b = s:byte(i)
        end
        if i == u_start then return nil, "expected unit at " .. i end
        local unit = s:sub(u_start, i - 1):lower()
        local mult = DURATION_UNIT_MS[unit]
        if not mult then return nil, "unknown unit: " .. unit end
        total_ms = total_ms + num * mult
    end
    if neg then total_ms = -total_ms end
    return total_ms
end

function M.duration(x)
    if type(x) == "string" then
        local ms, err = parse_duration_string(x)
        if not ms then error("duration: " .. (err or "parse error")) end
        return new_duration(ms)
    elseif type(x) == "table" then
        local ms = 0
        if x.weeks        then ms = ms + x.weeks        * 604800000 end
        if x.days         then ms = ms + x.days         * 86400000  end
        if x.hours        then ms = ms + x.hours        * 3600000   end
        if x.minutes      then ms = ms + x.minutes      * 60000     end
        if x.seconds      then ms = ms + x.seconds      * 1000      end
        if x.milliseconds then ms = ms + x.milliseconds             end
        return new_duration(ms)
    elseif type(x) == "number" then
        -- bare number: seconds
        return new_duration(x * 1000)
    else
        error("duration: expected string, table, or number")
    end
end

M.Duration = Duration

-- ===== Datetime =======================================================

local Datetime = {}
Datetime.__index = Datetime

local function new_datetime(epoch, tz_offset)
    return setmetatable({
        _is_datetime = true,
        epoch_       = epoch,
        tz_offset_   = tz_offset or 0,
    }, Datetime)
end

local function decompose_local(dt)
    -- Return (y, mo, d, h, mi, s, ms) in the datetime's display zone.
    return epoch_to_ymdhms(dt.epoch_ + dt.tz_offset_)
end

-- Lazy field access (year, month, day, etc.) via __index.
local FIELD_LOOKUP = {
    year        = 1, month   = 2, day = 3,
    hour        = 4, minute  = 5, second = 6,
    millisecond = 7,
}

function Datetime:__index(k)
    local rawv = rawget(Datetime, k)
    if rawv ~= nil then return rawv end
    local idx = FIELD_LOOKUP[k]
    if idx then
        local y, mo, d, h, mi, s, ms = decompose_local(self)
        if idx == 1 then return y end
        if idx == 2 then return mo end
        if idx == 3 then return d end
        if idx == 4 then return h end
        if idx == 5 then return mi end
        if idx == 6 then return s end
        if idx == 7 then return ms end
    end
    if k == "tz_offset" then return self.tz_offset_ end
    return nil
end

function Datetime:weekday()
    local y, mo, d = decompose_local(self)
    return weekday_from_days(days_from_civil(y, mo, d))
end

function Datetime:yearday()
    local y, mo, d = decompose_local(self)
    return days_from_civil(y, mo, d) - days_from_civil(y, 1, 1) + 1
end

function Datetime:epoch()    return self.epoch_ end
function Datetime:epoch_ms() return math.floor(self.epoch_ * 1000) end

function Datetime:with_offset(off)
    return new_datetime(self.epoch_, off)
end

function Datetime:to_utc()
    return new_datetime(self.epoch_, 0)
end

function Datetime:to_local()
    return new_datetime(self.epoch_, M.local_offset(self.epoch_))
end

function Datetime.__add(a, b)
    if getmetatable(a) == Datetime and getmetatable(b) == Duration then
        return new_datetime(a.epoch_ + b.ms_ / 1000, a.tz_offset_)
    end
    if getmetatable(b) == Datetime and getmetatable(a) == Duration then
        return new_datetime(b.epoch_ + a.ms_ / 1000, b.tz_offset_)
    end
    error("datetime: can only add datetime + duration")
end

function Datetime.__sub(a, b)
    if getmetatable(a) == Datetime and getmetatable(b) == Datetime then
        return new_duration((a.epoch_ - b.epoch_) * 1000)
    end
    if getmetatable(a) == Datetime and getmetatable(b) == Duration then
        return new_datetime(a.epoch_ - b.ms_ / 1000, a.tz_offset_)
    end
    error("datetime: subtraction requires datetime-datetime or datetime-duration")
end

function Datetime.__eq(a, b)
    return getmetatable(a) == Datetime and getmetatable(b) == Datetime
       and a.epoch_ == b.epoch_
end

function Datetime.__lt(a, b) return a.epoch_ <  b.epoch_ end
function Datetime.__le(a, b) return a.epoch_ <= b.epoch_ end

function Datetime:__tostring() return self:to_iso8601() end

-- strftime-style format. Subset that covers the common patterns.
local function pad(n, w) return string.format("%0" .. w .. "d", n) end

local WDAY_LONG  = { "Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday" }
local WDAY_SHORT = { "Sun","Mon","Tue","Wed","Thu","Fri","Sat" }
local MON_LONG   = { "January","February","March","April","May","June",
                     "July","August","September","October","November","December" }
local MON_SHORT  = { "Jan","Feb","Mar","Apr","May","Jun",
                     "Jul","Aug","Sep","Oct","Nov","Dec" }

function Datetime:format(pattern)
    local y, mo, d, h, mi, s, ms = decompose_local(self)
    local wd = weekday_from_days(days_from_civil(y, mo, d))
    local yd = days_from_civil(y, mo, d) - days_from_civil(y, 1, 1) + 1
    local off = self.tz_offset_
    local out = pattern:gsub("%%(.)", function(c)
        if c == "Y" then return pad(y, 4) end
        if c == "y" then return pad(y % 100, 2) end
        if c == "m" then return pad(mo, 2) end
        if c == "d" then return pad(d, 2) end
        if c == "H" then return pad(h, 2) end
        if c == "M" then return pad(mi, 2) end
        if c == "S" then return pad(s, 2) end
        if c == "L" then return pad(ms, 3) end
        if c == "j" then return pad(yd, 3) end
        if c == "w" then return tostring(wd) end
        if c == "A" then return WDAY_LONG[wd + 1] end
        if c == "a" then return WDAY_SHORT[wd + 1] end
        if c == "B" then return MON_LONG[mo] end
        if c == "b" then return MON_SHORT[mo] end
        if c == "p" then return h < 12 and "AM" or "PM" end
        if c == "I" then local h12 = h % 12; if h12 == 0 then h12 = 12 end; return pad(h12, 2) end
        if c == "%" then return "%" end
        if c == "z" then
            local sign = off < 0 and "-" or "+"
            local mag  = off < 0 and -off or off
            return string.format("%s%02d%02d", sign, floor(mag / 3600), floor((mag % 3600) / 60))
        end
        if c == "Z" then
            if off == 0 then return "UTC" end
            local sign = off < 0 and "-" or "+"
            local mag  = off < 0 and -off or off
            return string.format("UTC%s%02d:%02d", sign, floor(mag / 3600), floor((mag % 3600) / 60))
        end
        return "%" .. c
    end)
    return out
end

local function format_offset(off)
    if off == 0 then return "+00:00" end
    local sign = off < 0 and "-" or "+"
    local mag  = off < 0 and -off or off
    return string.format("%s%02d:%02d", sign, floor(mag / 3600), floor((mag % 3600) / 60))
end

function Datetime:to_iso8601(opts)
    opts = opts or {}
    local utc           = opts.utc
    local frac_digits   = opts.fractional or 0
    local with_offset   = opts.with_offset
    if with_offset == nil then with_offset = true end
    local epoch         = utc and self.epoch_ or (self.epoch_ + self.tz_offset_)
    local y, mo, d, h, mi, s, ms = epoch_to_ymdhms(epoch)
    local frac_str = ""
    if frac_digits > 0 then
        if frac_digits == 3 then
            frac_str = string.format(".%03d", ms)
        else
            local sub = (self.epoch_ - floor(self.epoch_))
            frac_str = "." .. string.format("%0" .. frac_digits .. "d",
                math.floor(sub * (10 ^ frac_digits) + 0.5))
        end
    end
    local off_str = ""
    if with_offset then
        if utc then
            off_str = "Z"
        else
            off_str = format_offset(self.tz_offset_)
        end
    end
    return string.format("%04d-%02d-%02dT%02d:%02d:%02d%s%s",
        y, mo, d, h, mi, s, frac_str, off_str)
end

M.Datetime = Datetime

-- ===== Datetime constructors ==========================================

function M.date(y, mo, d)
    return new_datetime(ymdhms_to_epoch(y, mo or 1, d or 1, 0, 0, 0, 0), 0)
end

function M.time(h, mi, s, ms)
    local y, mo, d = epoch_to_ymdhms(M.now())
    return new_datetime(ymdhms_to_epoch(y, mo, d, h or 0, mi or 0, s or 0, ms or 0), 0)
end

function M.datetime(y, mo, d, h, mi, s, ms, tz_offset)
    return new_datetime(
        ymdhms_to_epoch(y, mo or 1, d or 1, h or 0, mi or 0, s or 0, ms or 0)
        - (tz_offset or 0),
        tz_offset or 0)
end

function M.from_epoch(epoch, tz_offset)
    return new_datetime(epoch, tz_offset or 0)
end

function M.now_dt(tz_offset)
    return new_datetime(M.now(), tz_offset or 0)
end

-- ===== ISO 8601 parser ================================================

local function parse_offset_str(s)
    if not s or s == "" then return nil, "missing offset" end
    if s == "Z" or s == "z" then return 0 end
    local sign, hh, mm = s:match("^([%+%-])(%d%d):?(%d%d)$")
    if sign then
        local off = (tonumber(hh) * 60 + tonumber(mm)) * 60
        if sign == "-" then off = -off end
        return off
    end
    local s2, h2 = s:match("^([%+%-])(%d%d)$")
    if s2 then
        local off = tonumber(h2) * 3600
        if s2 == "-" then off = -off end
        return off
    end
    return nil, "bad offset: " .. s
end

local function split_offset(s)
    if s:sub(-1) == "Z" or s:sub(-1) == "z" then
        return s:sub(1, -2), s:sub(-1)
    end
    for i = #s, math.max(2, #s - 6), -1 do
        local b = s:byte(i)
        if b == 0x2B or b == 0x2D then
            return s:sub(1, i - 1), s:sub(i)
        end
    end
    return s, nil
end

function M.parse_iso8601(s)
    if type(s) ~= "string" or s == "" then return nil, "empty input" end
    local date_part, time_part = s:match("^([^Tt ]+)[Tt ](.+)$")
    if not date_part then date_part = s end

    local y, mo, d
    local yy, mm, dd = date_part:match("^(%-?%d+)%-(%d%d)%-(%d%d)$")
    if yy then
        y, mo, d = tonumber(yy), tonumber(mm), tonumber(dd)
    else
        yy, mm, dd = date_part:match("^(%d%d%d%d)(%d%d)(%d%d)$")
        if yy then y, mo, d = tonumber(yy), tonumber(mm), tonumber(dd) end
    end
    if not y then
        local yo, doy = date_part:match("^(%d%d%d%d)%-(%d%d%d)$")
        if not yo then yo, doy = date_part:match("^(%d%d%d%d)(%d%d%d)$") end
        if yo then
            doy = tonumber(doy)
            if doy < 1 or doy > (M.is_leap(tonumber(yo)) and 366 or 365) then
                return nil, "ordinal out of range"
            end
            local m = 1
            while doy > M.days_in_month(tonumber(yo), m) do
                doy = doy - M.days_in_month(tonumber(yo), m); m = m + 1
            end
            y, mo, d = tonumber(yo), m, doy
        end
    end
    if not y then return nil, "bad date: " .. date_part end
    if mo < 1 or mo > 12 then return nil, "bad month" end
    if d < 1 or d > M.days_in_month(y, mo) then return nil, "bad day" end

    local h, mi, sec, frac, offset = 0, 0, 0, 0, 0
    local has_offset = false
    if time_part then
        local body, off_str = split_offset(time_part)
        local hh, m1, s1, f1
        hh, m1, s1, f1 = body:match("^(%d%d):(%d%d):(%d%d)%.(%d+)$")
        if hh then
            h, mi, sec, frac = tonumber(hh), tonumber(m1), tonumber(s1), tonumber("0." .. f1)
        else
            hh, m1, s1 = body:match("^(%d%d):(%d%d):(%d%d)$")
            if hh then
                h, mi, sec = tonumber(hh), tonumber(m1), tonumber(s1)
            else
                hh, m1 = body:match("^(%d%d):(%d%d)$")
                if hh then
                    h, mi = tonumber(hh), tonumber(m1)
                else
                    return nil, "bad time: " .. body
                end
            end
        end
        if off_str then
            local o, oe = parse_offset_str(off_str)
            if not o then return nil, oe end
            offset = o; has_offset = true
        end
    end
    local epoch = ymdhms_to_epoch(y, mo, d, h, mi, sec, 0) + frac - offset
    return new_datetime(epoch, has_offset and offset or 0)
end

function M.format_iso8601(t, opts)
    if type(t) == "number" then
        return new_datetime(t, 0):to_iso8601(opts)
    end
    return t:to_iso8601(opts)
end

-- ===== Calendar arithmetic ============================================

function M.add_days(t, n)
    return new_datetime(t.epoch_ + n * 86400, t.tz_offset_)
end

local function add_months_impl(t, n)
    local y, mo, d, h, mi, s, ms = decompose_local(t)
    local total = (y * 12) + (mo - 1) + n
    local ny = floor(total / 12)
    local nmo = (total % 12) + 1
    local dim = M.days_in_month(ny, nmo)
    if d > dim then d = dim end
    local new_local = ymdhms_to_epoch(ny, nmo, d, h, mi, s, ms)
    return new_datetime(new_local - t.tz_offset_, t.tz_offset_)
end

function M.add_months(t, n) return add_months_impl(t, n) end
function M.add_years(t, n)  return add_months_impl(t, n * 12) end

function M.start_of_day(t)
    local y, mo, d = decompose_local(t)
    local local_epoch = ymdhms_to_epoch(y, mo, d, 0, 0, 0, 0)
    return new_datetime(local_epoch - t.tz_offset_, t.tz_offset_)
end

function M.start_of_month(t)
    local y, mo = decompose_local(t)
    local local_epoch = ymdhms_to_epoch(y, mo, 1, 0, 0, 0, 0)
    return new_datetime(local_epoch - t.tz_offset_, t.tz_offset_)
end

function M.start_of_year(t)
    local y = decompose_local(t)
    local local_epoch = ymdhms_to_epoch(y, 1, 1, 0, 0, 0, 0)
    return new_datetime(local_epoch - t.tz_offset_, t.tz_offset_)
end

-- ===== Internal helpers exposed for sibling packages ==================

M._days_from_civil   = days_from_civil
M._civil_from_days   = civil_from_days
M._epoch_to_ymdhms   = epoch_to_ymdhms
M._ymdhms_to_epoch   = ymdhms_to_epoch
M._weekday_from_days = weekday_from_days
M._new_datetime      = new_datetime
M._new_duration      = new_duration

return M
