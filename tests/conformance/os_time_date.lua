-- os library determinism: os.time / os.date / os.difftime with FIXED inputs.
-- The compiled exe and the interpreter run on the same machine (same timezone),
-- so every result must agree byte-for-byte even where the absolute value is
-- machine-dependent (the differential oracle compares the two engines, not a
-- hardcoded expectation).

local function show(...)
  local p = {}
  for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
  print(table.concat(p, "\t"))
end

-- broken-down local time -> timestamp
local t = os.time({ year = 2020, month = 6, day = 15, hour = 12, min = 30, sec = 45 })
show(math.type(t), t > 0)

-- timestamp -> broken-down (local), field by field (never print the table)
local bt = os.date("*t", t)
show(bt.year, bt.month, bt.day, bt.hour, bt.min, bt.sec, bt.wday, bt.yday, type(bt.isdst))

-- round-trip: os.time(os.date("*t", t)) == t
local t2 = os.time(bt)
show(t == t2)

-- UTC formatting (timezone-independent given t)
show(os.date("!%Y-%m-%d", t))
show(os.date("!%H:%M:%S", t))
show(os.date("!%j", t))            -- day of year, zero-padded
show(os.date("!%A %B", t))         -- full weekday + month name

-- os.difftime
show(os.difftime(t + 3661, t))     -- 3661
show(os.difftime(t, t + 100))      -- -100

-- %% and literal text in a format
show(os.date("!100%% [%Y]", t))

-- a span of consecutive days formats monotonically
do
  local day = 24 * 3600
  local out = {}
  for i = 0, 5 do out[#out + 1] = os.date("!%w", t + i * day) end  -- weekday number 0-6
  print(table.concat(out, ","))
end

print("[+] PASS os_time_date")
