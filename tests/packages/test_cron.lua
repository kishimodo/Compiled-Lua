-- tests/packages/test_cron.lua : cron-expression parsing + next/prev/matches
-- for the builtin `cron` package (distinct from the `cron_expr` package).
-- cron does all datetime math in UTC, so we build every "from" instant via
-- time.datetime(...,0) (explicit UTC offset) and read result fields straight
-- back -- no wallclock, no os.time, fully deterministic across JIT/interp.
--
-- Reference: 2021-01-01 is a Friday (weekday 5); the next Monday is 2021-01-04.

local ok_req, cron = pcall(require, "cron")
if not ok_req then print("[~] SKIP test_cron (" .. tostring(cron) .. ")") os.exit(0) end

local time = require "time"

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_cron: " .. tostring(m)) end end

-- Build a UTC datetime; cron operates in UTC and these display in UTC too.
local function U(y, mo, d, h, mi, s) return time.datetime(y, mo, d, h, mi, s or 0, 0, 0) end
-- Compare a returned datetime's UTC fields against expected.
local function same(dt, y, mo, d, h, mi, s)
  if dt == nil then return false end
  return dt.year == y and dt.month == mo and dt.day == d
     and dt.hour == h and dt.minute == mi and dt.second == (s or 0)
end

-- ===== validity / parse errors ========================================
ok(cron.is_valid("0 0 * * *") == true, "valid 5-field expr")
ok(cron.is_valid("99 * * * *") == false, "minute 99 is out of range (0..59)")
ok(cron.is_valid("* 24 * * *") == false, "hour 24 is out of range (0..23)")
ok(cron.is_valid("* * * 13 *") == false, "month 13 is out of range (1..12)")
ok(cron.is_valid("1 2 3") == false, "3 fields is too few for the default 5-field layout")
ok(select(2, cron.parse("garbage here too few")) ~= nil, "parse of bad expr returns an error msg")

-- ===== */15 * * * * : next/prev/matches ===============================
local q = cron.parse("*/15 * * * *")
ok(q ~= nil, "parse */15 returned a cron")
-- 10:07 -> next quarter is 10:15.
ok(same(q:next(U(2021, 1, 1, 10, 7, 0)), 2021, 1, 1, 10, 15, 0), "next */15 from 10:07 -> 10:15")
-- next() is strictly after, so from exactly 10:15 we jump to 10:30.
ok(same(q:next(U(2021, 1, 1, 10, 15, 0)), 2021, 1, 1, 10, 30, 0), "next */15 from 10:15 -> 10:30 (strict-after)")
-- prev() is at-or-before, so prev from 10:07 lands on 10:00.
ok(same(q:prev(U(2021, 1, 1, 10, 7, 0)), 2021, 1, 1, 10, 0, 0), "prev */15 from 10:07 -> 10:00")
-- :45 rolls over to the top of the next hour.
ok(same(q:next(U(2021, 1, 1, 10, 45, 0)), 2021, 1, 1, 11, 0, 0), "next */15 from 10:45 -> 11:00")
ok(q:matches(U(2021, 1, 1, 10, 30, 0)) == true,  "*/15 matches :30")
ok(q:matches(U(2021, 1, 1, 10, 31, 0)) == false, "*/15 does NOT match :31")

-- ===== weekday field: Monday midnight =================================
local mon = cron.parse("0 0 * * 1")
ok(same(mon:next(U(2021, 1, 1, 10, 7, 0)), 2021, 1, 4, 0, 0, 0), "next Monday-midnight after Fri 2021-01-01 -> 2021-01-04")
ok(mon:matches(U(2021, 1, 4, 0, 0, 0)) == true,  "matches Monday 2021-01-04 00:00")
ok(mon:matches(U(2021, 1, 4, 0, 1, 0)) == false, "does NOT match Monday 00:01")
ok(mon:matches(U(2021, 1, 1, 0, 0, 0)) == false, "does NOT match Friday 00:00")
-- Sunday=7 normalization: "* * * * 7" should match Sundays.
local sun7 = cron.parse("0 0 * * 7")
-- 2021-01-03 is the first Sunday of 2021.
ok(sun7:matches(U(2021, 1, 3, 0, 0, 0)) == true, "dow=7 normalizes to Sunday and matches 2021-01-03")

-- ===== aliases ========================================================
local daily = cron.parse("@daily")   -- 0 0 * * *
ok(same(daily:next(U(2021, 1, 1, 10, 7, 0)), 2021, 1, 2, 0, 0, 0), "@daily next midnight is the following day")
local yearly = cron.parse("@yearly") -- 0 0 1 1 *
ok(same(yearly:next(U(2021, 6, 15, 12, 0, 0)), 2022, 1, 1, 0, 0, 0), "@yearly from mid-2021 -> 2022-01-01")
local hourly = cron.parse("@hourly") -- 0 * * * *
ok(same(hourly:next(U(2021, 1, 1, 10, 30, 0)), 2021, 1, 1, 11, 0, 0), "@hourly next is the top of the next hour")

-- ===== 6-field seconds layout =========================================
local s6 = cron.parse("*/30 * * * * *", { seconds = true })
ok(s6 ~= nil, "parse 6-field seconds expr")
ok(same(s6:next(U(2021, 1, 1, 10, 0, 5)), 2021, 1, 1, 10, 0, 30), "seconds */30 from 10:00:05 -> 10:00:30")
ok(s6:matches(U(2021, 1, 1, 10, 0, 30)) == true,  "seconds */30 matches :30")
ok(s6:matches(U(2021, 1, 1, 10, 0, 31)) == false, "seconds */30 does NOT match :31")

-- ===== L (last day of month) ==========================================
local lastday = cron.parse("0 0 L * *")
-- January 2021 has 31 days.
ok(same(lastday:next(U(2021, 1, 15, 0, 0, 0)), 2021, 1, 31, 0, 0, 0), "next 'L' from Jan 15 -> Jan 31")
-- February 2021 (non-leap) has 28 days.
ok(lastday:matches(U(2021, 2, 28, 0, 0, 0)) == true,  "'L' matches Feb 28 in 2021")
ok(lastday:matches(U(2021, 2, 27, 0, 0, 0)) == false, "'L' does NOT match Feb 27 in 2021")

-- ===== specific date: 0 0 1 1 * (new year) ============================
local newyear = cron.parse("0 0 1 1 *")
ok(same(newyear:next(U(2021, 6, 1, 0, 0, 0)), 2022, 1, 1, 0, 0, 0), "next Jan-1-midnight from mid-2021 -> 2022")
ok(same(newyear:prev(U(2021, 6, 1, 0, 0, 0)), 2021, 1, 1, 0, 0, 0), "prev Jan-1-midnight from mid-2021 -> 2021-01-01")

-- ===== describe / matches sanity ======================================
ok(type(cron.describe("@daily")) == "string", "describe returns a string")
ok(cron.parse("@daily"):matches(U(2021, 1, 1, 0, 0, 0)) == true, "@daily matches midnight")
ok(cron.parse("@daily"):matches(U(2021, 1, 1, 0, 1, 0)) == false, "@daily does NOT match 00:01")

-- ===== iter yields strictly increasing instants =======================
local it = cron.parse("0 * * * *"):iter(U(2021, 1, 1, 0, 30, 0))
local a = it()
local b = it()
local cc = it()
ok(same(a, 2021, 1, 1, 1, 0, 0), "iter #1 -> 01:00")
ok(same(b, 2021, 1, 1, 2, 0, 0), "iter #2 -> 02:00")
ok(same(cc, 2021, 1, 1, 3, 0, 0), "iter #3 -> 03:00")

if fails == 0 then print("[+] PASS test_cron") os.exit(0) else os.exit(1) end
