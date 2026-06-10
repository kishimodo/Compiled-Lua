-- tests/packages/test_time.lua : calendar math, durations, ISO 8601 for the
-- builtin `time` package. Every "expected" value below is hand-computed from
-- the proleptic Gregorian calendar (NOT taken from the package's own output)
-- and is timezone-independent: we only ever assert CONVERSIONS of fixed epoch
-- inputs, never the current wallclock. This keeps the JIT/interpreter stdout
-- byte-identical (the runner cross-checks both).
--
-- Reference instants (UTC):
--   epoch 0           = 1970-01-01T00:00:00Z  (Thursday, weekday 4)
--   epoch 1609459200  = 2021-01-01T00:00:00Z  (Friday,   weekday 5)
--   epoch 1500000000  = 2017-07-14T02:40:00Z
--   epoch 1709208000  = 2024-02-29T12:00:00Z  (leap day)

local ok_req, time = pcall(require, "time")
if not ok_req then print("[~] SKIP test_time (" .. tostring(time) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_time: " .. tostring(m)) end end

-- ===== leap years / days in month (pure calendar) =====================
ok(time.is_leap(2000) == true,  "2000 is a leap year (div by 400)")
ok(time.is_leap(1900) == false, "1900 is NOT a leap year (div by 100, not 400)")
ok(time.is_leap(2024) == true,  "2024 is a leap year")
ok(time.is_leap(2023) == false, "2023 is not a leap year")
ok(time.days_in_month(2024, 2) == 29, "Feb 2024 has 29 days")
ok(time.days_in_month(2023, 2) == 28, "Feb 2023 has 28 days")
ok(time.days_in_month(2024, 4) == 30, "Apr has 30 days")
ok(time.days_in_month(2024, 12) == 31, "Dec has 31 days")

-- ===== from_epoch decomposition (fixed epoch -> known UTC fields) ======
local dt = time.from_epoch(1609459200, 0)   -- 2021-01-01T00:00:00Z
ok(dt.year == 2021, "epoch 1609459200 year is 2021")
ok(dt.month == 1,   "epoch 1609459200 month is 1")
ok(dt.day == 1,     "epoch 1609459200 day is 1")
ok(dt.hour == 0,    "epoch 1609459200 hour is 0")
ok(dt.minute == 0,  "epoch 1609459200 minute is 0")
ok(dt.second == 0,  "epoch 1609459200 second is 0")
ok(dt:weekday() == 5, "2021-01-01 is a Friday (weekday 5)")
ok(dt:yearday() == 1, "2021-01-01 is yearday 1")
ok(dt:epoch() == 1609459200, "round-trip epoch() returns input")

local dt2 = time.from_epoch(1500000000, 0)  -- 2017-07-14T02:40:00Z
ok(dt2.year == 2017 and dt2.month == 7 and dt2.day == 14, "epoch 1500000000 -> 2017-07-14")
ok(dt2.hour == 2 and dt2.minute == 40 and dt2.second == 0, "epoch 1500000000 -> 02:40:00")

-- epoch 0 is the Unix epoch, a Thursday.
local dt0 = time.from_epoch(0, 0)
ok(dt0.year == 1970 and dt0.month == 1 and dt0.day == 1, "epoch 0 -> 1970-01-01")
ok(dt0:weekday() == 4, "1970-01-01 is a Thursday (weekday 4)")

-- ===== datetime() constructor with explicit offset ====================
-- 2021-01-01 00:00:00 in UTC+0 must have epoch 1609459200.
local c = time.datetime(2021, 1, 1, 0, 0, 0, 0, 0)
ok(c:epoch() == 1609459200, "datetime(2021,1,1) epoch matches")
-- Same wallclock at UTC+5 is 5h *earlier* in absolute time.
local c5 = time.datetime(2021, 1, 1, 0, 0, 0, 0, 5 * 3600)
ok(c5:epoch() == 1609459200 - 5 * 3600, "datetime with +5h offset is 5h earlier in UTC")
-- The +5h datetime displays the same local fields it was built with.
ok(c5.year == 2021 and c5.hour == 0, "offset datetime keeps its local wallclock fields")

-- ===== date() / yearday on a leap day =================================
local leap = time.from_epoch(1709208000, 0)  -- 2024-02-29T12:00:00Z
ok(leap.month == 2 and leap.day == 29, "epoch 1709208000 -> Feb 29 (leap)")
-- 2024-02-29 is the 60th day of the year (31 Jan + 29 Feb).
ok(leap:yearday() == 60, "2024-02-29 is yearday 60")

-- ===== ISO 8601 parse (known string -> known epoch) ===================
local p = time.parse_iso8601("2021-01-01T00:00:00Z")
ok(p ~= nil and p:epoch() == 1609459200, "parse 2021-01-01T00:00:00Z -> epoch 1609459200")
local p2 = time.parse_iso8601("2017-07-14T02:40:00Z")
ok(p2 ~= nil and p2:epoch() == 1500000000, "parse 2017-07-14T02:40:00Z -> epoch 1500000000")
-- Offset: 12:00:00+05:00 is the same instant as 07:00:00Z.
local poff = time.parse_iso8601("2021-01-01T05:00:00+05:00")
ok(poff ~= nil and poff:epoch() == 1609459200, "parse +05:00 offset normalizes to UTC instant")
-- Round-trip: format then parse.
local iso = time.from_epoch(1500000000, 0):to_iso8601({ utc = true })
ok(iso == "2017-07-14T02:40:00Z", "to_iso8601 utc produces expected string, got: " .. tostring(iso))
local rt = time.parse_iso8601(iso)
ok(rt ~= nil and rt:epoch() == 1500000000, "format->parse round-trips epoch")
-- Bad input returns nil (not an error).
local bad = time.parse_iso8601("not-a-date")
ok(bad == nil, "parsing garbage returns nil")

-- ===== format() strftime subset ======================================
local f = time.from_epoch(1609459200, 0)  -- 2021-01-01 00:00:00 UTC, Friday
ok(f:format("%Y-%m-%d") == "2021-01-01", "format %Y-%m-%d")
ok(f:format("%H:%M:%S") == "00:00:00",   "format %H:%M:%S")
ok(f:format("%A") == "Friday",           "format %A (full weekday)")
ok(f:format("%a") == "Fri",              "format %a (short weekday)")
ok(f:format("%B") == "January",          "format %B (full month)")
ok(f:format("%b") == "Jan",              "format %b (short month)")
ok(f:format("100%%done") == "100%done",  "format %% escapes percent")

-- ===== duration: parse string + arithmetic ============================
local d1 = time.duration("1h30m")
ok(d1:total_ms() == 90 * 60 * 1000, "duration '1h30m' is 90 minutes in ms")
ok(d1:minutes() == 90,              "duration '1h30m' is 90 minutes")
ok(d1:hours() == 1.5,               "duration '1h30m' is 1.5 hours")
local d2 = time.duration({ seconds = 30 })
ok(d2:total_ms() == 30000, "duration {seconds=30} is 30000 ms")
local sum = d1 + d2
ok(sum:total_ms() == 90 * 60 * 1000 + 30000, "duration addition")
local diff = d1 - d2
ok(diff:total_ms() == 90 * 60 * 1000 - 30000, "duration subtraction")
ok((-d2):total_ms() == -30000, "duration negation")
ok((time.duration("2h") == time.duration("120m")) == true, "2h equals 120m")
ok((time.duration("1h") < time.duration("2h")) == true,    "1h < 2h")
-- bare-number duration is seconds.
ok(time.duration(5):total_ms() == 5000, "duration(5) is 5 seconds")
-- bad unit errors.
ok(select(1, pcall(time.duration, "5flarbs")) == false, "duration with bad unit errors")

-- ===== datetime + duration arithmetic =================================
local base = time.from_epoch(1609459200, 0)   -- 2021-01-01T00:00:00Z
local plus = base + time.duration("1d")
ok(plus:epoch() == 1609459200 + 86400, "datetime + 1d advances by 86400s")
ok(plus.day == 2, "datetime + 1d -> Jan 2")
-- datetime - datetime -> duration
local span = plus - base
ok(span:total_ms() == 86400 * 1000, "datetime difference is one day in ms")

-- ===== calendar helpers ===============================================
-- add_months across a year boundary, clamping Jan 31 -> Feb 28.
local jan31 = time.datetime(2021, 1, 31, 0, 0, 0, 0, 0)
local feb = time.add_months(jan31, 1)
ok(feb.month == 2 and feb.day == 28, "add_months clamps Jan 31 + 1mo -> Feb 28 (2021)")
local dec = time.add_months(jan31, 11)
ok(dec.month == 12 and dec.day == 31, "add_months Jan 31 + 11mo -> Dec 31")
local nextyear = time.add_years(jan31, 1)
ok(nextyear.year == 2022 and nextyear.month == 1 and nextyear.day == 31, "add_years keeps month/day")
-- start_of helpers.
local mid = time.datetime(2021, 7, 14, 13, 45, 30, 0, 0)
ok(time.start_of_day(mid).hour == 0 and time.start_of_day(mid).day == 14, "start_of_day zeros the time")
ok(time.start_of_month(mid).day == 1 and time.start_of_month(mid).month == 7, "start_of_month -> day 1")
ok(time.start_of_year(mid).month == 1 and time.start_of_year(mid).day == 1, "start_of_year -> Jan 1")
-- add_days.
local d10 = time.add_days(base, 10)
ok(d10:epoch() == 1609459200 + 10 * 86400, "add_days 10 advances 10*86400s")

-- ===== equality / ordering between datetimes ==========================
local a = time.from_epoch(1609459200, 0)
local b = time.from_epoch(1609459200, 5 * 3600)  -- same instant, different display zone
ok((a == b) == true,  "same instant compares equal regardless of display zone")
ok((time.from_epoch(100, 0) < time.from_epoch(200, 0)) == true, "earlier instant is <")

if fails == 0 then print("[+] PASS test_time") os.exit(0) else os.exit(1) end
