local creditcard = require "creditcard"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_creditcard: " .. tostring(m)) end end

-- ===== Luhn (reference: 4111111111111111 is a known-valid Visa test PAN) =====
ok(creditcard.luhn("4111111111111111") == true,  "luhn valid 4111111111111111")
ok(creditcard.luhn("4111111111111112") == false, "luhn invalid 4111111111111112")
-- whitespace/dashes are stripped before processing
ok(creditcard.luhn("4111 1111 1111 1111") == true, "luhn strips spaces")
ok(creditcard.luhn("4111-1111-1111-1111") == true, "luhn strips dashes")
-- non-digits / too short reject
ok(creditcard.luhn("abcd") == false, "luhn rejects non-digits")
ok(creditcard.luhn("4") == false,    "luhn rejects length<2")
-- known-good Amex/Mastercard test PANs pass Luhn
ok(creditcard.luhn("378282246310005") == true,  "luhn valid amex test PAN")
ok(creditcard.luhn("5555555555554444") == true, "luhn valid mastercard test PAN")

-- ===== Brand classification (reference: IIN ranges) =====
-- Visa: leading 4
ok(creditcard.brand("4111111111111111") == "visa", "brand visa 4...")
-- Amex: 34 / 37, length 15
ok(creditcard.brand("378282246310005") == "amex", "brand amex 37...")
ok(creditcard.brand("348282246310005") == "amex", "brand amex 34...")
-- Mastercard classic range 51-55
ok(creditcard.brand("5105105105105100") == "mastercard", "brand mastercard 51...")
ok(creditcard.brand("5555555555554444") == "mastercard", "brand mastercard 55...")
-- Mastercard new range 2221-2720
ok(creditcard.brand("2223003122003222") == "mastercard", "brand mastercard 2221-2720")
-- non-digits -> nil
ok(creditcard.brand("not-a-card") == nil, "brand nil for non-digits")

-- ===== validate() return shape =====
local v = creditcard.validate("4111111111111111")
ok(type(v) == "table",        "validate returns table")
ok(v.valid == true,           "validate.valid true for good visa")
ok(v.brand == "visa",         "validate.brand visa")
ok(v.length_valid == true,    "validate.length_valid true (16-digit visa)")
ok(v.luhn_valid == true,      "validate.luhn_valid true")

-- bad luhn flips valid but keeps brand/length
local bad = creditcard.validate("4111111111111112")
ok(bad.valid == false,        "validate.valid false for bad-luhn visa")
ok(bad.brand == "visa",       "validate.brand still visa for bad-luhn")
ok(bad.luhn_valid == false,   "validate.luhn_valid false for bad-luhn")

-- ===== Ship-with test numbers: every published test PAN must validate() =====
ok(type(creditcard.test_numbers) == "table", "test_numbers table exposed")
for brand, list in pairs(creditcard.test_numbers) do
    for _, pan in ipairs(list) do
        local r = creditcard.validate(pan)
        ok(r.brand == brand, ("test number %s classifies as %s (got %s)"):format(pan, brand, tostring(r.brand)))
        ok(r.luhn_valid == true, ("test number %s passes luhn"):format(pan))
        ok(r.valid == true, ("test number %s fully valid"):format(pan))
    end
end

-- generate_test returns the first published number for a brand
ok(creditcard.generate_test("visa") == "4111111111111111", "generate_test visa")
ok(creditcard.generate_test("amex") == "378282246310005",  "generate_test amex")
ok(creditcard.generate_test("nope") == nil,                "generate_test unknown brand -> nil")

if fails == 0 then print("[+] PASS test_creditcard") os.exit(0) else os.exit(1) end
