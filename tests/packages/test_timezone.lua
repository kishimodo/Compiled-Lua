-- tests/packages/test_timezone.lua : IANA-style timezone lookups for the
-- builtin `timezone` package. We assert offsets/DST flags at FIXED epochs
-- (never the current time) so the output is byte-identical under the JIT and
-- the interpreter. The bundled zone table uses simple static DST rules:
--   US:  2nd Sun Mar 02:00 -> 1st Sun Nov 02:00
--   EU:  last Sun Mar -> last Sun Oct
-- Reference instants (UTC):
--   1626350400 = 2021-07-15T12:00:00Z  (N-hemisphere summer / DST active)
--   1610712000 = 2021-01-15T12:00:00Z  (N-hemisphere winter / standard)

local ok_req, timezone = pcall(require, "timezone")
if not ok_req then print("[~] SKIP test_timezone (" .. tostring(timezone) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_timezone: " .. tostring(m)) end end

local SUMMER = 1626350400   -- 2021-07-15T12:00:00Z
local WINTER = 1610712000   -- 2021-01-15T12:00:00Z

-- ===== UTC zone is a constant 0 offset =================================
local utc = timezone.get("UTC")
ok(utc.name == "UTC", "UTC zone name")
ok(utc:offset_at(SUMMER) == 0, "UTC offset is 0 in summer")
ok(utc:offset_at(WINTER) == 0, "UTC offset is 0 in winter")
ok(utc:is_dst(SUMMER) == false, "UTC never observes DST")
ok(utc:name_at(WINTER) == "UTC", "UTC short name")

-- ===== America/New_York: EST (-5) in winter, EDT (-4) in summer ========
local ny = timezone.get("America/New_York")
ok(ny:offset_at(WINTER) == -5 * 3600, "New_York winter offset is -5h (EST)")
ok(ny:offset_at(SUMMER) == -4 * 3600, "New_York summer offset is -4h (EDT)")
ok(ny:is_dst(WINTER) == false, "New_York is NOT in DST in January")
ok(ny:is_dst(SUMMER) == true,  "New_York IS in DST in July")
ok(ny:name_at(WINTER) == "EST", "New_York winter short name is EST")
ok(ny:name_at(SUMMER) == "EDT", "New_York summer short name is EDT")

-- ===== America/Los_Angeles: PST (-8) / PDT (-7) ========================
local la = timezone.get("America/Los_Angeles")
ok(la:offset_at(WINTER) == -8 * 3600, "LA winter offset is -8h (PST)")
ok(la:offset_at(SUMMER) == -7 * 3600, "LA summer offset is -7h (PDT)")

-- ===== Europe/London: GMT (+0) winter, BST (+1) summer ================
local lon = timezone.get("Europe/London")
ok(lon:offset_at(WINTER) == 0, "London winter offset is +0 (GMT)")
ok(lon:offset_at(SUMMER) == 1 * 3600, "London summer offset is +1h (BST)")
ok(lon:name_at(WINTER) == "GMT", "London winter name is GMT")
ok(lon:name_at(SUMMER) == "BST", "London summer name is BST")

-- ===== Europe/Paris: CET (+1) / CEST (+2) =============================
local par = timezone.get("Europe/Paris")
ok(par:offset_at(WINTER) == 1 * 3600, "Paris winter offset is +1h (CET)")
ok(par:offset_at(SUMMER) == 2 * 3600, "Paris summer offset is +2h (CEST)")

-- ===== No-DST zones: constant offset year round =======================
local tokyo = timezone.get("Asia/Tokyo")
ok(tokyo:offset_at(WINTER) == 9 * 3600, "Tokyo offset is +9h in winter")
ok(tokyo:offset_at(SUMMER) == 9 * 3600, "Tokyo offset is +9h in summer (no DST)")
ok(tokyo:is_dst(SUMMER) == false, "Tokyo never observes DST")

-- Asia/Kolkata is a half-hour zone (+5:30).
local kol = timezone.get("Asia/Kolkata")
ok(kol:offset_at(SUMMER) == 5 * 3600 + 1800, "Kolkata offset is +5:30 (19800s)")

-- America/Phoenix observes no DST (-7 year round).
local phx = timezone.get("America/Phoenix")
ok(phx:offset_at(WINTER) == -7 * 3600, "Phoenix winter offset is -7h")
ok(phx:offset_at(SUMMER) == -7 * 3600, "Phoenix summer offset is -7h (no DST)")

-- ===== Southern hemisphere: Australia/Sydney DST is inverted ==========
-- AEST (+10) standard; AEDT (+11) during the southern summer (our Jan).
local syd = timezone.get("Australia/Sydney")
ok(syd:offset_at(WINTER) == 11 * 3600, "Sydney is in DST (AEDT +11) in January")
ok(syd:offset_at(SUMMER) == 10 * 3600, "Sydney is standard (AEST +10) in July")
ok(syd:is_dst(WINTER) == true,  "Sydney DST active in southern summer (Jan)")
ok(syd:is_dst(SUMMER) == false, "Sydney standard in southern winter (Jul)")

-- ===== numeric UTC+N forms ============================================
local plus3 = timezone.get("UTC+03")
ok(plus3:offset_at(SUMMER) == 3 * 3600, "UTC+03 is +3h")
local minus5 = timezone.get("UTC-05")
ok(minus5:offset_at(SUMMER) == -5 * 3600, "UTC-05 is -5h")

-- ===== list() is sorted and contains known zones ======================
local zones = timezone.list()
ok(type(zones) == "table" and #zones > 10, "list returns a non-trivial array")
local sorted = true
for i = 2, #zones do if zones[i - 1] > zones[i] then sorted = false break end end
ok(sorted, "list() is sorted")
local function contains(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
ok(contains(zones, "UTC"), "list contains UTC")
ok(contains(zones, "America/New_York"), "list contains America/New_York")
ok(contains(zones, "Asia/Tokyo"), "list contains Asia/Tokyo")

-- ===== to_zone produces a datetime with the right display offset ======
local dt_ny = timezone.to_zone(SUMMER, "America/New_York")
ok(dt_ny.tz_offset == -4 * 3600, "to_zone sets the EDT display offset")
ok(dt_ny:epoch() == SUMMER, "to_zone preserves the underlying instant")
-- The displayed hour for 12:00Z in EDT (-4) is 08:00.
ok(dt_ny.hour == 8, "12:00Z displays as 08:00 in EDT")

-- ===== unknown zone errors ============================================
ok(select(1, pcall(timezone.get, "Mars/Olympus_Mons")) == false, "unknown zone errors")

if fails == 0 then print("[+] PASS test_timezone") os.exit(0) else os.exit(1) end
