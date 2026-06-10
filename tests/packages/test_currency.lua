local currency = require "currency"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_currency: " .. tostring(m)) end end

-- Standard fixed-point currencies must be UNCHANGED by the precision fix.
-- USD: 2 decimals, "$" prefix, en-US default => rounds 123.456 to 123.46.
ok(currency.format(123.456, "USD") == "$123.46",
   "USD 123.456 -> " .. currency.format(123.456, "USD"))
-- Trailing zeros on fixed-point currencies are preserved.
ok(currency.format(1.5, "USD") == "$1.50",
   "USD 1.5 -> " .. currency.format(1.5, "USD"))
ok(currency.format(1000, "USD") == "$1,000.00",
   "USD 1000 -> " .. currency.format(1000, "USD"))

-- BTC: 8 decimals, "\xE2\x82\xBF" (Bitcoin sign, U+20BF). 8dp must be unchanged,
-- including its trailing zeros.
ok(currency.format(0.12345678, "BTC") == "\xE2\x82\xBF0.12345678",
   "BTC 0.12345678 -> " .. currency.format(0.12345678, "BTC"))
ok(currency.format(1.5, "BTC") == "\xE2\x82\xBF1.50000000",
   "BTC 1.5 -> " .. currency.format(1.5, "BTC"))

-- ETH: declared 18 decimals -- beyond double precision. The result must NOT
-- contain a long IEEE-754 garbage run of 9s or 0s.
local eth = currency.format(0.3, "ETH")
ok(select(2, eth:gsub("9999999999", "")) == 0, "ETH 0.3 has 9-garbage run: " .. eth)
ok(select(2, eth:gsub("0000000000", "")) == 0, "ETH 0.3 has 0-garbage run: " .. eth)
-- And it should still carry the right magnitude/value.
ok(eth:find("0.3", 1, true) ~= nil, "ETH 0.3 lost its value: " .. eth)

local eth2 = currency.format(12345.3, "ETH")
ok(select(2, eth2:gsub("9999999999", "")) == 0, "ETH 12345.3 has 9-garbage run: " .. eth2)
ok(select(2, eth2:gsub("0000000000", "")) == 0, "ETH 12345.3 has 0-garbage run: " .. eth2)

-- JPY: 0 decimals, rounds; "\xC2\xA5" (yen sign) prefix.
ok(currency.format(1234.56, "JPY") == "\xC2\xA51,235",
   "JPY 1234.56 -> " .. currency.format(1234.56, "JPY"))

if fails == 0 then print("[+] PASS test_currency") os.exit(0) else os.exit(1) end
