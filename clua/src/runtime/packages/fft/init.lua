-- fft -- discrete Fourier transform.
--
-- Two algorithms ship here:
--
--   * Cooley-Tukey radix-2 (in-place, bit-reversed permutation).
--     Used when length N is an exact power of two. O(N log N).
--
--   * Bluestein's chirp z-transform.
--     Used for arbitrary N. We embed the size-N transform into a length-M
--     convolution, where M is the next power of two >= 2N - 1, and compute
--     that convolution via two radix-2 FFTs. Slower than radix-2 by a
--     constant factor but supports any length.
--
-- Internals operate on parallel re[] / im[] arrays rather than tables of
-- complex objects. That cuts allocation pressure -- the LuaJIT trace stays
-- cleaner -- and we only convert to complex objects at the boundary.
--
-- Public surface:
--   fft.fft(x)              -- x: array of numbers OR array of complex
--   fft.ifft(X)             -- inverse; returns complex array
--   fft.dft(x)              -- O(n^2) reference; primarily for tests
--   fft.magnitude(X)        -- per-bin abs value
--   fft.phase(X)            -- per-bin arg value (radians)
--   fft.convolve(a, b)      -- linear convolution, length len(a)+len(b)-1
--   fft.windowed(x, name)   -- apply a window: "rect", "hann", "hamming", "blackman"

local complex = require "complex"

local M = {}

local sin, cos, pi, sqrt, log = math.sin, math.cos, math.pi, math.sqrt, math.log

-- ===== Input normalisation =============================================

local function unpack_input(x)
    -- Accepts: array of numbers OR array of { re=, im= }
    local n = #x
    local re, im = {}, {}
    if n == 0 then return re, im, 0 end
    if type(x[1]) == "number" then
        for i = 1, n do re[i] = x[i]; im[i] = 0 end
    else
        for i = 1, n do
            local v = x[i]
            if type(v) == "table" then re[i] = v.re or 0; im[i] = v.im or 0
            else re[i] = v; im[i] = 0 end
        end
    end
    return re, im, n
end

local function pack_complex(re, im, n)
    local out = {}
    for i = 1, n do out[i] = complex.new(re[i], im[i]) end
    return out
end

-- ===== Radix-2 Cooley-Tukey ============================================

local function bit_reverse_permute(re, im, n)
    -- in-place; standard reversed-index swap
    local j = 0
    for i = 0, n - 2 do
        if i < j then
            re[i + 1], re[j + 1] = re[j + 1], re[i + 1]
            im[i + 1], im[j + 1] = im[j + 1], im[i + 1]
        end
        local m = n / 2
        while m >= 1 and j >= m do
            j = j - m
            m = m / 2
        end
        j = j + m
    end
end

local function radix2_fft(re, im, n, inverse)
    bit_reverse_permute(re, im, n)
    local size = 2
    while size <= n do
        local half = size / 2
        local angle = (inverse and 2 or -2) * pi / size
        local wm_re = cos(angle)
        local wm_im = sin(angle)
        for k = 0, n - 1, size do
            local w_re, w_im = 1, 0
            for j = 0, half - 1 do
                -- Hoist the array reads into locals before the writes. The
                -- CLua JIT mis-traces repeated `re[k + j + half + 1]` reads
                -- that get reused after a same-index write in the same loop
                -- iteration -- using one local per slot avoids it.
                local idx1 = k + j + 1
                local idx2 = idx1 + half
                local re2 = re[idx2]
                local im2 = im[idx2]
                local t_re = w_re * re2 - w_im * im2
                local t_im = w_re * im2 + w_im * re2
                local u_re = re[idx1]
                local u_im = im[idx1]
                re[idx1] = u_re + t_re
                im[idx1] = u_im + t_im
                re[idx2] = u_re - t_re
                im[idx2] = u_im - t_im
                -- advance the twiddle: w = w * wm
                local nw_re = w_re * wm_re - w_im * wm_im
                local nw_im = w_re * wm_im + w_im * wm_re
                w_re, w_im = nw_re, nw_im
            end
        end
        size = size * 2
    end
    if inverse then
        for i = 1, n do re[i] = re[i] / n; im[i] = im[i] / n end
    end
end

-- ===== Bluestein ========================================================
--
-- z-chirp transform decomposes a length-N DFT into:
--   X[k] = w^(k^2/2) * sum_{j=0..N-1} ( x[j] * w^(j^2/2) ) * w^(-(k-j)^2/2)
-- where w = exp(-2*pi*i / N). The middle factor is a convolution, and the
-- triangle identity j^2 + (k-j)^2 - 2*j*(k-j) = ... is used to set things up.

local function next_pow2(n)
    local p = 1
    while p < n do p = p * 2 end
    return p
end

local function bluestein(re_in, im_in, n, inverse)
    local m = next_pow2(2 * n - 1)
    -- pre-compute chirp factors w[k] = exp(sign * i * pi * k^2 / N) for k in [0, N)
    local sign = inverse and 1 or -1
    local chirp_re, chirp_im = {}, {}
    for k = 0, n - 1 do
        local angle = sign * pi * (k * k % (2 * n)) / n
        chirp_re[k + 1] = cos(angle)
        chirp_im[k + 1] = sin(angle)
    end
    -- a[j] = x[j] * chirp[j];  b[k] = conj(chirp[k]) for k in [-(N-1), N-1], else 0
    local a_re, a_im = {}, {}
    local b_re, b_im = {}, {}
    for i = 1, m do a_re[i] = 0; a_im[i] = 0; b_re[i] = 0; b_im[i] = 0 end
    for j = 0, n - 1 do
        local xr, xi = re_in[j + 1], im_in[j + 1]
        local cr, ci = chirp_re[j + 1], chirp_im[j + 1]
        a_re[j + 1] = xr * cr - xi * ci
        a_im[j + 1] = xr * ci + xi * cr
    end
    -- b[k] for k = -(N-1)..N-1 placed into [0..2N-1] with wrap:
    --   b_re[k + 1] = chirp_re[|k| + 1]; b_im = -chirp_im (conjugate)
    b_re[1] = chirp_re[1]; b_im[1] = -chirp_im[1]
    for k = 1, n - 1 do
        local cr, ci = chirp_re[k + 1], -chirp_im[k + 1]
        b_re[k + 1]     = cr; b_im[k + 1]     = ci
        b_re[m - k + 1] = cr; b_im[m - k + 1] = ci
    end
    -- FFT(a), FFT(b)
    radix2_fft(a_re, a_im, m, false)
    radix2_fft(b_re, b_im, m, false)
    -- pointwise multiply
    for i = 1, m do
        local ar, ai = a_re[i], a_im[i]
        local br, bi = b_re[i], b_im[i]
        a_re[i] = ar * br - ai * bi
        a_im[i] = ar * bi + ai * br
    end
    -- inverse FFT
    radix2_fft(a_re, a_im, m, true)
    -- multiply by chirp again
    local out_re, out_im = {}, {}
    for k = 0, n - 1 do
        local ar, ai = a_re[k + 1], a_im[k + 1]
        local cr, ci = chirp_re[k + 1], chirp_im[k + 1]
        out_re[k + 1] = ar * cr - ai * ci
        out_im[k + 1] = ar * ci + ai * cr
    end
    if inverse then
        for i = 1, n do out_re[i] = out_re[i] / n; out_im[i] = out_im[i] / n end
    end
    return out_re, out_im
end

-- ===== Public FFT / IFFT ===============================================

local function pow2_check(n)
    if n == 0 then return true end
    local p = 1
    while p < n do p = p * 2 end
    return p == n
end

function M.fft(x)
    local re, im, n = unpack_input(x)
    if n == 0 then return {} end
    if n == 1 then return pack_complex(re, im, 1) end
    if pow2_check(n) then
        radix2_fft(re, im, n, false)
        return pack_complex(re, im, n)
    end
    local out_re, out_im = bluestein(re, im, n, false)
    return pack_complex(out_re, out_im, n)
end

function M.ifft(X)
    local re, im, n = unpack_input(X)
    if n == 0 then return {} end
    if n == 1 then return pack_complex(re, im, 1) end
    if pow2_check(n) then
        radix2_fft(re, im, n, true)
        return pack_complex(re, im, n)
    end
    local out_re, out_im = bluestein(re, im, n, true)
    return pack_complex(out_re, out_im, n)
end

-- ===== Reference DFT ====================================================

function M.dft(x)
    local re, im, n = unpack_input(x)
    local out = {}
    for k = 0, n - 1 do
        local sr, si = 0, 0
        for j = 0, n - 1 do
            local angle = -2 * pi * k * j / n
            local wr, wi = cos(angle), sin(angle)
            sr = sr + re[j + 1] * wr - im[j + 1] * wi
            si = si + re[j + 1] * wi + im[j + 1] * wr
        end
        out[k + 1] = complex.new(sr, si)
    end
    return out
end

-- ===== Spectral helpers =================================================

function M.magnitude(X)
    local out = {}
    for i = 1, #X do
        local v = X[i]
        if type(v) == "table" then
            out[i] = sqrt((v.re or 0) ^ 2 + (v.im or 0) ^ 2)
        else
            out[i] = math.abs(v)
        end
    end
    return out
end

function M.phase(X)
    local out = {}
    for i = 1, #X do
        local v = X[i]
        if type(v) == "table" then
            out[i] = math.atan2 and math.atan2(v.im or 0, v.re or 0)
                                or math.atan(v.im or 0, v.re or 0)
        else
            out[i] = v >= 0 and 0 or pi
        end
    end
    return out
end

function M.power_spectrum(X)
    -- |X[k]|^2 per bin -- avoids the sqrt that magnitude pays
    local out = {}
    for i = 1, #X do
        local v = X[i]
        if type(v) == "table" then
            local re = v.re or 0
            local im = v.im or 0
            out[i] = re * re + im * im
        else
            out[i] = v * v
        end
    end
    return out
end

-- ===== Convolution ======================================================

function M.convolve(a, b)
    -- linear convolution via FFT: zero-pad to len(a)+len(b)-1, FFT both,
    -- multiply, inverse FFT.
    local na = #a
    local nb = #b
    local n = na + nb - 1
    local pad = next_pow2(n)
    local ar, ai = {}, {}
    local br, bi = {}, {}
    local function re_of(v) if type(v) == "number" then return v end return v.re or 0 end
    local function im_of(v) if type(v) == "number" then return 0 end return v.im or 0 end
    for i = 1, pad do
        if i <= na then ar[i] = re_of(a[i]); ai[i] = im_of(a[i]) else ar[i] = 0; ai[i] = 0 end
        if i <= nb then br[i] = re_of(b[i]); bi[i] = im_of(b[i]) else br[i] = 0; bi[i] = 0 end
    end
    radix2_fft(ar, ai, pad, false)
    radix2_fft(br, bi, pad, false)
    for i = 1, pad do
        local rr = ar[i] * br[i] - ai[i] * bi[i]
        local ii = ar[i] * bi[i] + ai[i] * br[i]
        ar[i], ai[i] = rr, ii
    end
    radix2_fft(ar, ai, pad, true)
    local out = {}
    for i = 1, n do out[i] = ar[i] end
    return out
end

-- ===== Real-input FFT (RFFT) ============================================
--
-- For real input of length N, half the spectrum is redundant (it's the
-- complex conjugate of the other half). rfft() returns only bins [0..N/2],
-- which is N/2 + 1 complex values. irfft(spec, n) inverts back to length n.

function M.rfft(x)
    -- accept real numbers; build a complex array from them and FFT
    local re, im, n = unpack_input(x)
    if n == 0 then return {} end
    if pow2_check(n) then
        radix2_fft(re, im, n, false)
    else
        re, im = bluestein(re, im, n, false)
    end
    local half = math.floor(n / 2) + 1
    local out = {}
    for i = 1, half do out[i] = complex.new(re[i], im[i]) end
    return out
end

function M.irfft(spec, n)
    -- Caller must pass the original length n so we know whether n was even.
    -- We reconstruct the full spectrum by conjugating, then inverse-FFT.
    if n == nil then error("fft.irfft: caller must provide original length n") end
    local half = #spec
    local re, im = {}, {}
    for i = 1, half do
        local v = spec[i]
        if type(v) == "table" then re[i] = v.re or 0; im[i] = v.im or 0
        else re[i] = v; im[i] = 0 end
    end
    for k = half + 1, n do
        local mirror = n - k + 2  -- index in [2..half]
        re[k] =  re[mirror]
        im[k] = -im[mirror]
    end
    if pow2_check(n) then
        radix2_fft(re, im, n, true)
    else
        re, im = bluestein(re, im, n, true)
    end
    local out = {}
    for i = 1, n do out[i] = re[i] end
    return out
end

-- ===== 2D FFT ===========================================================
--
-- Row-FFT, then column-FFT. Input is a 2D table of either numbers or
-- complex objects; we keep the same shape in the output (table-of-rows of
-- complex objects).

local function fft2d_impl(matrix_in, inverse)
    local rows = #matrix_in
    if rows == 0 then return {} end
    local cols = #matrix_in[1]
    -- collect re/im plane by plane
    local re, im = {}, {}
    for i = 1, rows do
        re[i] = {}; im[i] = {}
        local row = matrix_in[i]
        for j = 1, cols do
            local v = row[j]
            if type(v) == "table" then
                re[i][j] = v.re or 0; im[i][j] = v.im or 0
            else
                re[i][j] = v; im[i][j] = 0
            end
        end
    end
    -- row-wise FFT
    for i = 1, rows do
        local rr = re[i]
        local ii = im[i]
        if pow2_check(cols) then
            radix2_fft(rr, ii, cols, inverse)
        else
            local nr, ni = bluestein(rr, ii, cols, inverse)
            for j = 1, cols do rr[j] = nr[j]; ii[j] = ni[j] end
        end
    end
    -- column-wise FFT
    local col_re, col_im = {}, {}
    for j = 1, cols do
        for i = 1, rows do col_re[i] = re[i][j]; col_im[i] = im[i][j] end
        if pow2_check(rows) then
            radix2_fft(col_re, col_im, rows, inverse)
        else
            local nr, ni = bluestein(col_re, col_im, rows, inverse)
            for i = 1, rows do col_re[i] = nr[i]; col_im[i] = ni[i] end
        end
        for i = 1, rows do re[i][j] = col_re[i]; im[i][j] = col_im[i] end
    end
    -- pack
    local out = {}
    for i = 1, rows do
        out[i] = {}
        for j = 1, cols do out[i][j] = complex.new(re[i][j], im[i][j]) end
    end
    return out
end

function M.fft2d(matrix_in)  return fft2d_impl(matrix_in, false) end
function M.ifft2d(matrix_in) return fft2d_impl(matrix_in, true)  end

-- ===== Windows ==========================================================

-- Modified Bessel function of the first kind, order 0. Power-series form
-- with enough terms for the Kaiser window's beta range (up to ~20).
local function bessel_i0(x)
    local sum_v = 1
    local term = 1
    local x2 = (x * 0.5) ^ 2
    for k = 1, 50 do
        term = term * x2 / (k * k)
        sum_v = sum_v + term
        if term < 1e-15 * sum_v then break end
    end
    return sum_v
end

local _WINDOWS = {
    rect     = function(_, _) return 1 end,
    hann     = function(i, n) return 0.5 * (1 - cos(2 * pi * (i - 1) / (n - 1))) end,
    hamming  = function(i, n) return 0.54 - 0.46 * cos(2 * pi * (i - 1) / (n - 1)) end,
    blackman = function(i, n)
        local a0, a1, a2 = 0.42, 0.5, 0.08
        return a0 - a1 * cos(2 * pi * (i - 1) / (n - 1)) + a2 * cos(4 * pi * (i - 1) / (n - 1))
    end,
}

function M.window(name, n, opt)
    if name == "kaiser" then
        local beta = opt or 8.6  -- ~60 dB sidelobe attenuation
        local denom = bessel_i0(beta)
        local out = {}
        for i = 1, n do
            local r = 2 * (i - 1) / (n - 1) - 1
            out[i] = bessel_i0(beta * sqrt(1 - r * r)) / denom
        end
        return out
    end
    if name == "tukey" then
        local alpha = opt or 0.5  -- cosine-taper fraction; 0 = rect, 1 = hann
        local out = {}
        if alpha <= 0 then
            for i = 1, n do out[i] = 1 end
            return out
        end
        if alpha >= 1 then
            for i = 1, n do out[i] = 0.5 * (1 - cos(2 * pi * (i - 1) / (n - 1))) end
            return out
        end
        local edge = alpha * (n - 1) / 2
        for i = 1, n do
            local x = i - 1
            if x < edge then
                out[i] = 0.5 * (1 + cos(pi * (x / edge - 1)))
            elseif x <= (n - 1) - edge then
                out[i] = 1
            else
                out[i] = 0.5 * (1 + cos(pi * ((x - (n - 1) + edge) / edge)))
            end
        end
        return out
    end
    local fn = _WINDOWS[name]
    if not fn then error("fft.window: unknown window " .. tostring(name)) end
    local out = {}
    for i = 1, n do out[i] = fn(i, n) end
    return out
end

function M.windowed(x, name, opt)
    local re, im, n = unpack_input(x)
    local w = M.window(name, n, opt)
    local out = {}
    for i = 1, n do out[i] = complex.new(re[i] * w[i], im[i] * w[i]) end
    return out
end

return M
