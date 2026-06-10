-- tests/packages/test_fft.lua : DFT/FFT correctness. Compiled to a standalone
-- exe by the runner (which bundles the fft package) and run.
--
-- We check fft against (a) hand-computed reference values, (b) the package's
-- own O(n^2) dft, for a power-of-two length (radix-2 path) and a
-- non-power-of-two length (Bluestein path), and (c) the inverse round-trip.
local fft = require "fft"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_fft: " .. tostring(m)) end end

local EPS = 1e-9
local function close(a, b) return math.abs(a - b) <= EPS end

-- fft/ifft/dft return arrays of complex objects ({re=,im=}).
local function approx_eq(A, B, tag)
    ok(#A == #B, tag .. ": length " .. #A .. " == " .. #B)
    for i = 1, #A do
        ok(close(A[i].re, B[i].re), tag .. ": re[" .. i .. "] " .. A[i].re .. " ~ " .. B[i].re)
        ok(close(A[i].im, B[i].im), tag .. ": im[" .. i .. "] " .. A[i].im .. " ~ " .. B[i].im)
    end
end

-- ---- Power-of-two (radix-2): hand-computed reference --------------------
-- x = {1, 2, 3, 4}. DFT_k = sum_j x[j] * exp(-2*pi*i*k*j/4).
--   X0 = 1+2+3+4                       = 10 + 0i
--   X1 = 1 - 2i - 3 + 4i              = -2 + 2i
--   X2 = 1 - 2 + 3 - 4               = -2 + 0i
--   X3 = 1 + 2i - 3 - 4i              = -2 - 2i
do
    local x = {1, 2, 3, 4}
    local X = fft.fft(x)
    local ref = {
        {re = 10, im = 0},
        {re = -2, im = 2},
        {re = -2, im = 0},
        {re = -2, im = -2},
    }
    approx_eq(X, ref, "pow2 reference")
    -- fft matches the package's own reference dft
    approx_eq(X, fft.dft(x), "pow2 vs dft")
    -- round-trip
    local xi = fft.ifft(X)
    for i = 1, #x do
        ok(close(xi[i].re, x[i]), "pow2 ifft re[" .. i .. "] = " .. xi[i].re)
        ok(close(xi[i].im, 0),    "pow2 ifft im[" .. i .. "] = " .. xi[i].im)
    end
end

-- ---- Non-power-of-two (Bluestein): hand-computed reference --------------
-- x = {1, 2, 3}. DFT_k = sum_j x[j]*exp(-2*pi*i*k*j/3).
--   X0 = 1+2+3 = 6 + 0i
--   w  = exp(-2*pi*i/3) = -1/2 - (sqrt3/2) i
--   X1 = 1 + 2w + 3w^2 = -1.5 + (sqrt3/2) i  ~ -1.5 + 0.8660254...i
--   X2 = conj(X1)                            = -1.5 - 0.8660254...i
do
    local x = {1, 2, 3}
    local X = fft.fft(x)
    local s = math.sqrt(3) / 2
    local ref = {
        {re = 6,    im = 0},
        {re = -1.5, im = s},
        {re = -1.5, im = -s},
    }
    approx_eq(X, ref, "bluestein reference")
    -- fft matches the package's own reference dft (also exercises Bluestein)
    approx_eq(X, fft.dft(x), "bluestein vs dft")
    -- round-trip
    local xi = fft.ifft(X)
    for i = 1, #x do
        ok(close(xi[i].re, x[i]), "bluestein ifft re[" .. i .. "] = " .. xi[i].re)
        ok(close(xi[i].im, 0),    "bluestein ifft im[" .. i .. "] = " .. xi[i].im)
    end
end

-- ---- Larger non-power-of-two: fft vs dft + round-trip -------------------
do
    local x = {}
    for i = 1, 6 do x[i] = (i * 7 + 3) % 11 end  -- deterministic real input, n=6
    local X = fft.fft(x)
    approx_eq(X, fft.dft(x), "n6 vs dft")
    local xi = fft.ifft(X)
    for i = 1, #x do
        ok(close(xi[i].re, x[i]), "n6 ifft re[" .. i .. "]")
        ok(close(xi[i].im, 0),    "n6 ifft im[" .. i .. "]")
    end
end

if fails == 0 then print("[+] PASS test_fft") os.exit(0) else os.exit(1) end
