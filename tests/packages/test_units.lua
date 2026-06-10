-- tests/packages/test_units.lua : units.parse must not steal a trailing digit
-- of a bare number into a bogus "unit" (parse("100") used to return 10,"0"),
-- while still splitting real "<number><unit>" inputs.
local units = require "units"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_units: " .. tostring(m)) end end

local function check(text, exp_n, exp_u)
  local n, u = units.parse(text)
  ok(n == exp_n and u == exp_u,
     string.format("parse(%q) == (%s,%s) got (%s,%s)", text,
       tostring(exp_n), tostring(exp_u), tostring(n), tostring(u)))
end

-- Bare dimensionless numbers -- no unit, exact value (the regressed case).
check("100", 100, nil)
check("42", 42, nil)
check("7.5", 7.5, nil)
check("123", 123, nil)
check("5", 5, nil)
check("-13", -13, nil)
check("1e3", 1000, nil)

-- Value + unit still parses.
check("5 m", 5, "m")
check("3.14kg", 3.14, "kg")
check("1e3 W", 1000, "W")
check("-2.5e-3 A", -2.5e-3, "A")
check("100%", 100, "%")

-- A temperature conversion sanity (known-correct path), if the API exists.
if type(units.convert) == "function" then
  local okc, c = pcall(units.convert, 0, "C", "F")
  if okc and type(c) == "number" then ok(math.abs(c - 32) < 1e-9, "convert 0C -> 32F") end
end

if fails == 0 then print("[+] PASS test_units") os.exit(0) else os.exit(1) end
