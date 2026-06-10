local iban = require "iban"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_iban: " .. tostring(m)) end end

-- ===== validate: known-good real IBANs (mod-97 == 1) =====
-- validate() returns (true, country, check_digits) on success, (nil, err) on failure.
local v1, country1, cd1 = iban.validate("GB82WEST12345698765432")
ok(v1 == true, "validate GB82WEST12345698765432 should be true")
ok(country1 == "GB", "country of GB IBAN should be GB, got " .. tostring(country1))
ok(cd1 == "82", "check digits of GB IBAN should be 82, got " .. tostring(cd1))

-- A second real, independently-known IBAN.
local v2, country2, cd2 = iban.validate("DE89370400440532013000")
ok(v2 == true, "validate DE89370400440532013000 should be true")
ok(country2 == "DE", "country of DE IBAN should be DE, got " .. tostring(country2))
ok(cd2 == "89", "check digits of DE IBAN should be 89, got " .. tostring(cd2))

-- The task's exact form: (validate(x)) == true.
ok((iban.validate("GB82WEST12345698765432")) == true, "(validate GB) == true")

-- ===== is_valid convenience wrapper returns a plain bool =====
ok(iban.is_valid("GB82WEST12345698765432") == true, "is_valid GB true")
ok(iban.is_valid("DE89370400440532013000") == true, "is_valid DE true")

-- ===== flipping one character must break the checksum =====
-- Change the last digit 2 -> 3; mod-97 must now fail.
ok(iban.is_valid("GB82WEST12345698765433") == false, "flipped last char must be invalid")
-- validate() on the flipped value returns nil (falsey), not true.
local vbad = iban.validate("GB82WEST12345698765433")
ok(vbad ~= true, "validate of flipped char must not be true")
-- Corrupt the check digits 82 -> 83.
ok(iban.is_valid("GB83WEST12345698765432") == false, "flipped check digit must be invalid")

-- ===== rejection of malformed input =====
ok(iban.is_valid("GB82WEST1234569876543") == false, "wrong length (too short) invalid")
ok(iban.is_valid("ZZ00XXXX00000000000000") == false, "unknown country invalid")
ok(iban.is_valid("") == false, "empty string invalid")
ok(iban.is_valid("GBXXWEST12345698765432") == false, "non-digit check digits invalid")

-- ===== format inserts spaces in groups of 4 =====
ok(iban.format("GB82WEST12345698765432") == "GB82 WEST 1234 5698 7654 32",
   "format groups of 4 for GB IBAN")
-- Already-spaced / lowercase input is normalized then re-grouped.
ok(iban.format("gb82 west 1234 5698 7654 32") == "GB82 WEST 1234 5698 7654 32",
   "format normalizes case and spacing")
-- DE IBAN is length 22 -> 5 groups of 4 + a final group of 2.
ok(iban.format("DE89370400440532013000") == "DE89 3704 0044 0532 0130 00",
   "format groups of 4 for DE IBAN")
ok(iban.format("") == "", "format of empty string is empty")

-- ===== checksum: compute the 2 check digits for a "00" candidate =====
-- Replacing GB82 -> GB00 and recomputing must yield "82".
ok(iban.checksum("GB00WEST12345698765432") == "82", "checksum recovers GB check digits 82")
ok(iban.checksum("DE00370400440532013000") == "89", "checksum recovers DE check digits 89")

-- ===== parse: structured decomposition =====
local p = iban.parse("GB82WEST12345698765432")
ok(type(p) == "table", "parse returns a table")
if type(p) == "table" then
  ok(p.country == "GB", "parse country GB")
  ok(p.check_digits == "82", "parse check_digits 82")
  ok(p.bban == "WEST12345698765432", "parse bban")
  -- GB spec: bank {1,4}, branch {5,10}, account {11,18} within the BBAN.
  ok(p.bank_code == "WEST", "parse bank_code WEST")
  ok(p.branch_code == "123456", "parse branch_code 123456")
  ok(p.account_number == "98765432", "parse account_number 98765432")
end
-- parse on an invalid IBAN returns nil + error.
local pbad = iban.parse("GB82WEST12345698765433")
ok(pbad == nil, "parse of invalid IBAN returns nil")

if fails == 0 then print("[+] PASS test_iban") os.exit(0) else os.exit(1) end
