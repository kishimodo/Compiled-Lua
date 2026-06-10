local complex = require "complex"

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_complex: " .. tostring(m)) end end

local EPS = 1e-9
local function near(a, b) return math.abs(a - b) <= EPS end

-- assert a complex value (re, im) against known-correct reference numbers
local function approx(z, re, im, m)
    ok(near(z.re, re), (m or "?") .. ": re=" .. tostring(z.re) .. " want " .. tostring(re))
    ok(near(z.im, im), (m or "?") .. ": im=" .. tostring(z.im) .. " want " .. tostring(im))
end

-- field accessors / constructor
local z = complex.new(3, 4)
ok(z.re == 3, "new re field")
ok(z.im == 4, "new im field")
ok(complex.real(z) == 3, "real() accessor")
ok(complex.imag(z) == 4, "imag() accessor")
ok(complex.new(7).im == 0, "im defaults to 0")

-- abs(3+4i) = 5   (3-4-5 triangle)
ok(near(complex.abs(complex.new(3, 4)), 5), "abs(3+4i)=5")

-- sqrt(-4) = 2i
approx(complex.sqrt(complex.new(-4, 0)), 0, 2, "sqrt(-4)=2i")

-- sqrt(3+4i) = 2+i
approx(complex.sqrt(complex.new(3, 4)), 2, 1, "sqrt(3+4i)=2+i")

-- sqrt(-3-4i) = 1-2i  (principal branch)
approx(complex.sqrt(complex.new(-3, -4)), 1, -2, "sqrt(-3-4i)=1-2i")

-- arg(1+i) = pi/4   (pins the atan2 dependency)
ok(near(complex.arg(complex.new(1, 1)), math.pi / 4), "arg(1+i)=pi/4")

-- exp(i*pi) ~= -1 (Euler's identity)
approx(complex.exp(complex.new(0, math.pi)), -1, 0, "exp(i*pi)=-1")

-- (1+i)*(1-i) = 2
approx(complex.mul(complex.new(1, 1), complex.new(1, -1)), 2, 0, "(1+i)*(1-i)=2")

-- add: (1+2i)+(3+4i) = 4+6i
approx(complex.add(complex.new(1, 2), complex.new(3, 4)), 4, 6, "add")

-- complex.i is 0+1i
ok(complex.i.re == 0 and complex.i.im == 1, "complex.i == 0+1i")

-- method-call form via metatable __index also works
approx(complex.new(3, 4):sqrt(), 2, 1, "method sqrt(3+4i)=2+i")

if fails == 0 then print("[+] PASS test_complex") os.exit(0) else os.exit(1) end
