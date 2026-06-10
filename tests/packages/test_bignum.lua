-- Regression test for the builtin `bignum` package (arbitrary-precision ints).
-- All expected values are KNOWN-CORRECT references computed independently
-- (.NET System.Numerics.BigInteger / hand math), NOT echoes of the package's
-- own output.
local bignum = require "bignum"

local fails = 0
local function ok(c, m)
    if not c then
        fails = fails + 1
        print("[-] FAIL test_bignum: " .. tostring(m))
    end
end

local new = bignum.new
local function S(bn, base) return bignum.tostring(bn, base) end

-- ---- limb-boundary multiply: 2^200 * 2^200 == 2^400 -------------------
-- 2^24 is one limb; 2^400 spans ~17 limbs.
local two = new(2)
local p200 = bignum.pow(two, 200)
local p400 = bignum.mul(p200, p200)
local expect_2pow400 =
    "2582249878086908589655919172003011874329705792829223512830659356540647622016841194629645353280137831435903171972747493376"
ok(S(p400) == expect_2pow400, "2^200 * 2^200 == 2^400")
ok(bignum.eq(p400, bignum.pow(two, 400)), "pow(2,400) matches mul")

-- ---- Karatsuba-boundary multiply (>=40 limbs = >=960 bits ~ 290 digits) -
-- a = 300 sevens, b = 300 nines; both ~997 bits (~42 limbs) -> Karatsuba path.
-- Reference product (from .NET BigInteger): "7"*299 .. "6" .. "2"*299 .. "3".
local a300 = new(string.rep("7", 300))
local b300 = new(string.rep("9", 300))
local prod = bignum.mul(a300, b300)
local expect_prod = string.rep("7", 299) .. "6" .. string.rep("2", 299) .. "3"
ok(#expect_prod == 600, "reference Karatsuba product is 600 digits")
ok(S(prod) == expect_prod, "Karatsuba-range product (300x300 digits)")

-- ---- divmod identities -------------------------------------------------
-- Truncate-toward-zero: a == (a//b)*b + (a%b), with sign(r)=sign(a). For a
-- POSITIVE divisor (and negative dividend) the package is correct.
local function check_divmod(astr, bstr)
    local A, B = new(astr), new(bstr)
    local q, r = bignum.divmod(A, B)
    local recon = bignum.add(bignum.mul(q, B), r)
    ok(bignum.eq(recon, A), "divmod identity a==q*b+r for " .. astr .. " / " .. bstr)
    local qb = bignum.div(bignum.mul(A, B), B)
    ok(bignum.eq(qb, A), "(a*b)//b==a for " .. astr .. " , " .. bstr)
end
check_divmod("123456789012345678901234567890", "987654321")
check_divmod("-123456789012345678901234567890", "987654321")

-- A NEGATIVE divisor whose magnitude needs the multi-limb division path
-- (|b| >= 2^24 = 16777216). udivmod used to run signed M.mul/M.sub against the
-- negative `divisor` instead of its magnitude, producing a wrong q/r
-- (BIGNUM-001, now fixed by normalising both operands to magnitude). The
-- truncate-toward-zero identity a == q*b + r must hold and |r| < |b|.
do
    local A, B = new("123456789012345678901234567890"), new("-987654321")
    local q, r = bignum.divmod(A, B)
    local recon = bignum.add(bignum.mul(q, B), r)
    ok(bignum.eq(recon, A), "divmod neg multi-limb divisor: a == q*b+r")
    ok(bignum.lt(bignum.abs(r), bignum.abs(B)), "divmod neg multi-limb divisor: |r| < |b|")
end
do
    local A, B = new("-123456789012345678901234567890"), new("-987654321")
    local q, r = bignum.divmod(A, B)
    local recon = bignum.add(bignum.mul(q, B), r)
    ok(bignum.eq(recon, A), "divmod neg dividend + neg multi-limb divisor: a == q*b+r")
end

-- Single-limb negative divisor (|b| < 2^24) IS correct -> hard assertion.
do
    local q, r = bignum.divmod(new("123456789012345678901234567890"), new(-16777215))
    local recon = bignum.add(bignum.mul(q, new(-16777215)), r)
    ok(bignum.eq(recon, new("123456789012345678901234567890")),
       "divmod with negative single-limb divisor (|b|<2^24) is correct")
end
-- spot-check exact known truncating quotient/remainder (single-limb)
do
    local q, r = bignum.divmod(new(-17), new(5))
    ok(S(q) == "-3", "trunc divmod -17/5 quotient == -3")
    ok(S(r) == "-2", "trunc divmod -17/5 remainder == -2 (sign of dividend)")
    local q2, r2 = bignum.divmod(new(17), new(-5))
    ok(S(q2) == "-3", "trunc divmod 17/-5 quotient == -3")
    ok(S(r2) == "2", "trunc divmod 17/-5 remainder == 2 (sign of dividend)")
end

-- ---- powmod(2,1000,1000000007) -- precomputed reference -----------------
-- reference (independent .NET BigInteger.ModPow and full 2^1000 mod): 688423210
local pm = bignum.powmod(new(2), 1000, new(1000000007))
ok(S(pm) == "688423210", "powmod(2,1000,1000000007) == 688423210")

-- ---- modinv: modinv(a,m)*a % m == 1 ------------------------------------
-- modinv(17, 1000000007) == 352941179 (reference; m is prime so a^(m-2) mod m)
local mi = bignum.modinv(new(17), new(1000000007))
ok(S(mi) == "352941179", "modinv(17,1000000007) == 352941179")
local prodmod = bignum.mod(bignum.mul(mi, new(17)), new(1000000007))
ok(S(prodmod) == "1", "modinv(a,m)*a % m == 1")

-- ---- isqrt: isqrt(n)^2 <= n < (isqrt(n)+1)^2 ---------------------------
local nsq = new("123456789012345678901234567890123456789012345678901234567890")
local r = bignum.isqrt(nsq)
ok(S(r) == "351364182882014425311122238169", "isqrt of 60-digit n == reference")
local r2 = bignum.mul(r, r)
local rp1 = bignum.add(r, new(1))
local rp1_2 = bignum.mul(rp1, rp1)
ok(bignum.le(r2, nsq), "isqrt(n)^2 <= n")
ok(bignum.lt(nsq, rp1_2), "n < (isqrt(n)+1)^2")
-- perfect square boundary
do
    local k = new(1000000)
    local sq = bignum.mul(k, k)         -- 10^12
    ok(S(bignum.isqrt(sq)) == "1000000", "isqrt of perfect square 10^12 == 10^6")
end

-- ---- factorial(20) == 2432902008176640000 ------------------------------
ok(S(bignum.factorial(20)) == "2432902008176640000", "factorial(20)")

-- ---- tostring / parse round-trip in base 10 and 16 ---------------------
local dec = "987654321987654321987654321987654321987654321987654321"
local rt10 = S(new(dec, 10), 10)
ok(rt10 == dec, "round-trip base 10")
-- base 16: render hex, parse it back, compare
local hx = "deadbeefcafebabe0123456789abcdef0123456789abcdef"
local fromhex = new(hx, 16)
ok(S(fromhex, 16) == hx, "round-trip base 16 (tostring)")
ok(bignum.eq(new(S(fromhex, 16), 16), fromhex), "round-trip base 16 (parse back)")
-- cross-base: same magnitude parsed from dec and from its hex form are equal
do
    local v = new("1234567890123456789012345678901234567890", 10)
    local hexform = S(v, 16)
    ok(bignum.eq(new(hexform, 16), v), "dec value equals its base-16 round-trip")
end
-- negative round-trip
ok(S(new("-100000000000000000000000000001")) == "-100000000000000000000000000001",
   "negative decimal round-trip")

if fails == 0 then
    print("[+] PASS test_bignum")
    os.exit(0)
else
    os.exit(1)
end
