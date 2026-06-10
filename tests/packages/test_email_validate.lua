local email_validate = require "email_validate"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_email_validate: " .. tostring(m)) end end

-- A plain hostname domain is valid.
ok(email_validate.is_valid("a@x.com") == true, "a@x.com should be valid")
-- Trailing dot in domain must be rejected (RFC: empty trailing label).
ok(email_validate.is_valid("a@x.com.") == false, "a@x.com. trailing dot should be invalid")
-- Empty domain label (consecutive dots) must be rejected.
ok(email_validate.is_valid("a@x..com") == false, "a@x..com empty label should be invalid")
-- Multi-label domain is valid.
ok(email_validate.is_valid("foo@bar.example.org") == true, "foo@bar.example.org should be valid")

if fails == 0 then print("[+] PASS test_email_validate") os.exit(0) else os.exit(1) end
