-- Regression test for the builtin `cron_expr` package.
--
-- cron_expr is pure Lua (no native DLL). Its time math runs through
-- os.time/os.date in *local* time, so every assertion below builds base
-- epochs from explicit field tables and reads results back as field tables
-- via os.date("*t", ...). That keeps the expected values timezone-independent
-- (we never hard-code a raw epoch integer). All "expected" values are
-- hand-computed from the calendar, not taken from the code's own output.

local ok_req, cron = pcall(require, "cron_expr")
if not ok_req then print("[~] SKIP test_cron_expr") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_cron_expr: " .. tostring(m)) end end

-- Build a local-time epoch from calendar fields.
local function E(y, mo, d, h, mi, se)
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se or 0 })
end

-- Assert that `epoch` decodes to the given calendar fields. wday is Lua's
-- 1..7 (1=Sunday) convention; pass nil to skip the weekday check.
local function expect_time(label, epoch, y, mo, d, h, mi, se, wday)
  ok(epoch ~= nil, label .. ": next_after returned nil")
  if epoch == nil then return end
  local t = os.date("*t", epoch)
  local got = string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
  local want = string.format("%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, se)
  ok(got == want, label .. ": expected " .. want .. " got " .. got)
  if wday ~= nil then ok(t.wday == wday, label .. ": expected wday " .. wday .. " got " .. t.wday) end
end

local function list_eq(a, b)
  if type(a) ~= "table" then return false end
  if #a ~= #b then return false end
  for i = 1, #b do if a[i] ~= b[i] then return false end end
  return true
end

-- ===== parse + next_after / matches: "*/15 * * * *" ====================
-- minutes {0,15,30,45}, every hour, every day.
local ev = cron.parse("*/15 * * * *")
ok(ev ~= nil, "parse '*/15 * * * *' returned nil")
if ev then
  -- 10:07 -> next quarter is 10:15 (use 2024-04-10, a DST-free Wednesday).
  expect_time("*/15 from 10:07", ev:next_after(E(2024, 4, 10, 10, 7, 0)),
              2024, 4, 10, 10, 15, 0)
  -- 10:15:00 -> strictly after base, so next is 10:30:00.
  expect_time("*/15 from 10:15", ev:next_after(E(2024, 4, 10, 10, 15, 0)),
              2024, 4, 10, 10, 30, 0)
  -- 10:45:30 -> roll to the top of the next hour, 11:00:00.
  expect_time("*/15 from 10:45:30", ev:next_after(E(2024, 4, 10, 10, 45, 30)),
              2024, 4, 10, 11, 0, 0)
  ok(ev:matches(E(2024, 4, 10, 10, 30, 0)) == true,  "*/15 should match :30")
  ok(ev:matches(E(2024, 4, 10, 10, 31, 0)) == false, "*/15 should NOT match :31")
  ok(ev:matches(E(2024, 4, 10, 10, 30, 5)) == false, "*/15 should NOT match :30:05 (sec defaults to 0)")
end

-- ===== parse + next_after / matches: "0 0 * * 1" (Monday midnight) =====
-- 2024-04-10 is a Wednesday; the next Monday is 2024-04-15 (wday=2 in Lua).
local mon = cron.parse("0 0 * * 1")
ok(mon ~= nil, "parse '0 0 * * 1' returned nil")
if mon then
  expect_time("monday-midnight", mon:next_after(E(2024, 4, 10, 12, 0, 0)),
              2024, 4, 15, 0, 0, 0, 2)
  ok(mon:matches(E(2024, 4, 15, 0, 0, 0)) == true,  "monday-midnight should match Mon 00:00")
  ok(mon:matches(E(2024, 4, 15, 0, 1, 0)) == false, "monday-midnight should NOT match Mon 00:01")
  ok(mon:matches(E(2024, 4, 14, 0, 0, 0)) == false, "monday-midnight should NOT match Sun 00:00")
end

-- ===== named shortcuts: @yearly and @daily ============================
local yr = cron.parse("@yearly")  -- 0 0 1 1 *
ok(yr ~= nil, "parse '@yearly' returned nil")
if yr then
  expect_time("@yearly from mid-June", yr:next_after(E(2024, 6, 15, 10, 0, 0)),
              2025, 1, 1, 0, 0, 0)
end
local daily = cron.parse("@daily")  -- 0 0 * * *
ok(daily ~= nil, "parse '@daily' returned nil")
if daily then
  expect_time("@daily next midnight", daily:next_after(E(2024, 4, 10, 12, 30, 0)),
              2024, 4, 11, 0, 0, 0)
end

-- ===== 6-field form with a seconds column =============================
-- "*/30 * * * * *": seconds {0,30}. From 10:00:05 -> 10:00:30.
local s6 = cron.parse("*/30 * * * * *")
ok(s6 ~= nil, "parse 6-field returned nil")
if s6 then
  expect_time("seconds */30", s6:next_after(E(2024, 4, 10, 10, 0, 5)),
              2024, 4, 10, 10, 0, 30)
end

-- ===== fields(): per-field sorted integer lists =======================
local f = cron.fields("*/15 * * * *")
ok(f ~= nil and list_eq(f.minute, {0, 15, 30, 45}), "fields minute should be {0,15,30,45}")
ok(f ~= nil and #f.hour == 24, "fields hour should have 24 entries for '*'")
ok(f ~= nil and #f.month == 12, "fields month should have 12 entries for '*'")
ok(f ~= nil and f.sec == nil, "5-field expr should report no sec list")

local f6 = cron.fields("30 0 12 * * *")
ok(f6 ~= nil and list_eq(f6.sec, {30}), "6-field sec list should be {30}")
ok(f6 ~= nil and list_eq(f6.minute, {0}), "6-field minute list should be {0}")
ok(f6 ~= nil and list_eq(f6.hour, {12}), "6-field hour list should be {12}")

-- Named tokens and Sunday=7 normalization.
ok(list_eq(cron.fields("0 0 1 JAN *").month, {1}), "month JAN should resolve to {1}")
ok(list_eq(cron.fields("0 0 * * MON").dow, {1}), "dow MON should resolve to {1}")
ok(list_eq(cron.fields("0 0 * * 7").dow, {0}), "dow 7 should normalize to {0} (Sunday)")

-- ===== field range validation =========================================
ok(cron.validate("0 0 * * 1") == true, "valid expr should validate")
do
  local v = cron.validate("1 2 3")            -- only 3 fields
  ok(v == false, "3-field expr should fail validation")
end
do
  local v = cron.validate("99 * * * *")       -- minute > 59
  ok(v == false, "minute 99 should fail validation (range 0..59)")
end
do
  local v = cron.validate("* 24 * * *")       -- hour 24 > 23
  ok(v == false, "hour 24 should fail validation (range 0..23)")
end
do
  local v = cron.validate("* * * 13 *")       -- month 13 > 12
  ok(v == false, "month 13 should fail validation (range 1..12)")
end

-- ===== simplify(): canonical re-emission ==============================
-- A contiguous run compresses to a-b; a stepped set expands to its members.
ok(cron.simplify("0,1,2,3,4 * * * *") == "0-4 * * * *", "simplify should compress 0,1,2,3,4 -> 0-4")
ok(cron.simplify("*/15 * * * *") == "0,15,30,45 * * * *", "simplify should expand */15 -> 0,15,30,45")
ok(cron.simplify("* * * * *") == "* * * * *", "simplify of all-star is unchanged")

-- ===== set algebra: is_subset / union / intersection ==================
ok(cron.is_subset("0 * * * *", "0,30 * * * *") == true,  "{0} is a subset of {0,30}")
ok(cron.is_subset("0,30 * * * *", "0 * * * *") == false, "{0,30} is NOT a subset of {0}")
ok(cron.intersection("0,15,30 * * * *", "0,30,45 * * * *") == "0,30 * * * *",
   "intersection of {0,15,30} and {0,30,45} on minute is {0,30}")
ok(cron.union("0,15 * * * *", "30,45 * * * *") == "0,15,30,45 * * * *",
   "union of minute sets {0,15} and {30,45} is {0,15,30,45}")

if fails == 0 then print("[+] PASS test_cron_expr") os.exit(0) else os.exit(1) end
