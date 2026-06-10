local formula = require "formula"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_formula: " .. tostring(m)) end end

-- formula.eval(text, ctx) needs a ctx with a :get method; these formulas
-- reference no cells so a get that always returns nil suffices.
local ctx = { get = function(_, ref) return nil end }
local function eval(s) return formula.eval(s, ctx) end

-- Normal precedence: 10 + 2*3 == 16 (not (10+2)*3).
ok(eval("10 + 2*3") == 16, "10 + 2*3 should be 16, got " .. tostring(eval("10 + 2*3")))

-- Exponentiation operator.
ok(eval("2^3") == 8, "2^3 should be 8, got " .. tostring(eval("2^3")))

-- MOD() is the real modulo function: MOD(10,3) == 1.
ok(eval("MOD(10,3)") == 1, "MOD(10,3) should be 1, got " .. tostring(eval("MOD(10,3)")))

-- Regression: '%' is no longer a broken infix operator computing na/100*nb.
-- Spreadsheets have no binary '%'. eval("10 % 3") must NOT equal 0.3; it must
-- either error (an error sentinel) or, were it ever a modulo, equal 1 -- never 0.3.
local pct = eval("10 % 3")
ok(pct ~= 0.3, "'10 % 3' must NOT silently equal 0.3, got " .. tostring(pct))
ok(formula.is_error(pct) or pct == 1, "'10 % 3' must be an error or modulo, got " .. tostring(pct))

if fails == 0 then print("[+] PASS test_formula") os.exit(0) else os.exit(1) end
