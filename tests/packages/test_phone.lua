local phone = require "phone"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_phone: " .. tostring(m)) end end

-- Regression: NANP territory +1-670 (Northern Mariana Islands) must NOT be
-- swallowed by a bogus 4-digit "1670" calling code. It parses under "1"
-- with a 10-digit national number, and validates.
local p, err = phone.parse("+16702345678")
ok(p ~= nil, "parse(+16702345678) returned nil: " .. tostring(err))
if p then
  ok(p.country_code == "1", "country_code expected '1' got " .. tostring(p.country_code))
  ok(#p.national_number == 10, "national_number length expected 10 got " .. tostring(#p.national_number))
  ok(p.national_number == "6702345678", "national_number expected 6702345678 got " .. tostring(p.national_number))
end
ok(phone.is_valid("+16702345678") == true, "is_valid(+16702345678) expected true")

-- An ordinary +1 number still parses correctly.
local p2 = phone.parse("+12025551234")
ok(p2 ~= nil, "parse(+12025551234) returned nil")
if p2 then
  ok(p2.country_code == "1", "p2 country_code expected '1' got " .. tostring(p2.country_code))
  ok(#p2.national_number == 10, "p2 national_number length expected 10 got " .. tostring(#p2.national_number))
  ok(p2.national_number == "2025551234", "p2 national_number expected 2025551234 got " .. tostring(p2.national_number))
end
ok(phone.is_valid("+12025551234") == true, "is_valid(+12025551234) expected true")

if fails == 0 then print("[+] PASS test_phone") os.exit(0) else os.exit(1) end
