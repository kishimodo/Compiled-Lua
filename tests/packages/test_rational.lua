local ok_req, rational = pcall(require, "rational")
if not ok_req then print("[~] SKIP test_rational") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_rational: " .. tostring(m)) end end

local Q = rational.new

-- tostring gives canonical "n/d" (or "n" for integers); use it as the reference shape
local function s(r) return rational.tostring(r) end

-- ===== construction + reduction via gcd =====
ok(s(Q(2, 4)) == "1/2", "2/4 reduces to 1/2, got " .. s(Q(2, 4)))
ok(s(Q(6, 3)) == "2", "6/3 reduces to integer 2, got " .. s(Q(6, 3)))
ok(s(Q(0, 5)) == "0", "0/5 is 0, got " .. s(Q(0, 5)))
ok(s(Q(7)) == "7", "den defaults to 1, got " .. s(Q(7)))

-- sign lives on numerator; negative denominator moves sign up
ok(s(Q(1, -2)) == "-1/2", "1/-2 -> -1/2, got " .. s(Q(1, -2)))
ok(s(Q(-3, -6)) == "1/2", "-3/-6 -> 1/2, got " .. s(Q(-3, -6)))

-- ===== exact arithmetic =====
-- 1/2 + 1/3 = 5/6
ok(s(Q(1, 2) + Q(1, 3)) == "5/6", "1/2 + 1/3 = 5/6, got " .. s(Q(1, 2) + Q(1, 3)))
-- 1/2 - 1/3 = 1/6
ok(s(Q(1, 2) - Q(1, 3)) == "1/6", "1/2 - 1/3 = 1/6, got " .. s(Q(1, 2) - Q(1, 3)))
-- 2/3 * 3/4 = 1/2
ok(s(Q(2, 3) * Q(3, 4)) == "1/2", "2/3 * 3/4 = 1/2, got " .. s(Q(2, 3) * Q(3, 4)))
-- (1/2) / (3/4) = 2/3
ok(s(Q(1, 2) / Q(3, 4)) == "2/3", "(1/2)/(3/4) = 2/3, got " .. s(Q(1, 2) / Q(3, 4)))
-- negatives: -1/2 + 1/3 = -1/6
ok(s(Q(-1, 2) + Q(1, 3)) == "-1/6", "-1/2 + 1/3 = -1/6, got " .. s(Q(-1, 2) + Q(1, 3)))
-- unary minus
ok(s(-Q(3, 5)) == "-3/5", "unary minus, got " .. s(-Q(3, 5)))
-- adding to zero is identity
ok(s(Q(0) + Q(4, 7)) == "4/7", "0 + 4/7 = 4/7, got " .. s(Q(0) + Q(4, 7)))

-- ===== powers (integer exponent, incl negative) =====
ok(s(Q(2, 3) ^ 2) == "4/9", "(2/3)^2 = 4/9, got " .. s(Q(2, 3) ^ 2))
ok(s(Q(2, 3) ^ -1) == "3/2", "(2/3)^-1 = 3/2, got " .. s(Q(2, 3) ^ -1))
ok(s(Q(5, 7) ^ 0) == "1", "x^0 = 1, got " .. s(Q(5, 7) ^ 0))
ok(s(Q(2, 3) ^ -2) == "9/4", "(2/3)^-2 = 9/4, got " .. s(Q(2, 3) ^ -2))

-- ===== comparison =====
ok(Q(1, 3) < Q(1, 2), "1/3 < 1/2")
ok(not (Q(1, 2) < Q(1, 3)), "not 1/2 < 1/3")
ok(Q(2, 4) == Q(1, 2), "2/4 == 1/2 (value equality)")
ok(Q(1, 2) <= Q(1, 2), "1/2 <= 1/2")
ok(Q(-1, 2) < Q(1, 3), "-1/2 < 1/3 (sign-aware compare)")
ok(rational.cmp(Q(3, 4), Q(2, 4)) > 0, "cmp 3/4 vs 2/4 > 0")

-- ===== numer / denom (reduced form) =====
-- numer()/denom() return bignum values, so stringify via the builtin tostring
-- (bignum carries its own __tostring), NOT rational.tostring.
do
  local r = Q(8, 12) -- -> 2/3
  ok(tostring(r:numer()) == "2", "numer of 8/12 is 2, got " .. tostring(r:numer()))
  ok(tostring(r:denom()) == "3", "denom of 8/12 is 3, got " .. tostring(r:denom()))
end

-- ===== from_decimal: exact parse =====
-- 3.14 -> 314/100 -> reduced 157/50
ok(s(rational.from_decimal("3.14")) == "157/50",
   "from_decimal 3.14 = 157/50, got " .. s(rational.from_decimal("3.14")))
-- 0.5 -> 1/2
ok(s(rational.from_decimal("0.5")) == "1/2",
   "from_decimal 0.5 = 1/2, got " .. s(rational.from_decimal("0.5")))
-- negative decimal
ok(s(rational.from_decimal("-0.25")) == "-1/4",
   "from_decimal -0.25 = -1/4, got " .. s(rational.from_decimal("-0.25")))
-- exponent form: 1.5e1 = 15
ok(s(rational.from_decimal("1.5e1")) == "15",
   "from_decimal 1.5e1 = 15, got " .. s(rational.from_decimal("1.5e1")))
-- plain integer string
ok(s(rational.from_decimal("42")) == "42",
   "from_decimal 42 = 42, got " .. s(rational.from_decimal("42")))

-- ===== to_decimal: truncating expansion (independent reference) =====
-- 1/4 = 0.2500
ok(rational.to_decimal(Q(1, 4), 4) == "0.2500",
   "to_decimal 1/4 prec4 = 0.2500, got " .. rational.to_decimal(Q(1, 4), 4))
-- 1/3 truncated to 5 places = 0.33333
ok(rational.to_decimal(Q(1, 3), 5) == "0.33333",
   "to_decimal 1/3 prec5 = 0.33333, got " .. rational.to_decimal(Q(1, 3), 5))
-- 7/2 = 3.50
ok(rational.to_decimal(Q(7, 2), 2) == "3.50",
   "to_decimal 7/2 prec2 = 3.50, got " .. rational.to_decimal(Q(7, 2), 2))
-- negative: -3/4 = -0.75
ok(rational.to_decimal(Q(-3, 4), 2) == "-0.75",
   "to_decimal -3/4 prec2 = -0.75, got " .. rational.to_decimal(Q(-3, 4), 2))
-- precision 0 -> integer part only (truncated, not rounded)
ok(rational.to_decimal(Q(7, 2), 0) == "3",
   "to_decimal 7/2 prec0 = 3, got " .. rational.to_decimal(Q(7, 2), 0))

-- ===== from_decimal / to_decimal round-trip on a terminating value =====
do
  local r = rational.from_decimal("12.625") -- exact: 101/8
  ok(s(r) == "101/8", "12.625 = 101/8, got " .. s(r))
  ok(rational.to_decimal(r, 3) == "12.625", "round-trip 12.625, got " .. rational.to_decimal(r, 3))
end

-- ===== floor / ceil / trunc / sign / is_integer =====
-- floor/ceil/trunc return bignum values -> use builtin tostring
ok(tostring(rational.floor(Q(7, 2))) == "3", "floor(7/2)=3")
ok(tostring(rational.ceil(Q(7, 2))) == "4", "ceil(7/2)=4")
ok(tostring(rational.floor(Q(-7, 2))) == "-4", "floor(-7/2)=-4 (toward -inf)")
ok(tostring(rational.ceil(Q(-7, 2))) == "-3", "ceil(-7/2)=-3")
ok(tostring(rational.trunc(Q(-7, 2))) == "-3", "trunc(-7/2)=-3 (toward zero)")
ok(rational.sign(Q(-1, 5)) < 0, "sign of -1/5 negative")
ok(rational.sign(Q(0)) == 0, "sign of 0 is 0")
ok(rational.is_integer(Q(6, 3)), "6/3 is integer")
ok(not rational.is_integer(Q(1, 2)), "1/2 not integer")

-- ===== from_string: p/q and decimal forms =====
ok(s(rational.from_string("3/6")) == "1/2", "from_string 3/6 = 1/2, got " .. s(rational.from_string("3/6")))
ok(s(rational.from_string("2.5")) == "5/2", "from_string 2.5 = 5/2, got " .. s(rational.from_string("2.5")))
ok(s(rational.from_string("-4/8")) == "-1/2", "from_string -4/8 = -1/2, got " .. s(rational.from_string("-4/8")))

if fails == 0 then print("[+] PASS test_rational") os.exit(0) else os.exit(1) end
