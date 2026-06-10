-- complex -- Cartesian complex numbers backed by Lua doubles.
--
-- Representation:
--   c = { re = real, im = imag }
-- The metatable lifts arithmetic and transcendentals; values stay flat tables
-- so allocation is cheap (we create a new object per op -- complex arithmetic
-- is inherently allocation-heavy without escape analysis).
--
-- Branch cuts follow the C99 conventions:
--   log:  cut on the negative real axis
--   sqrt: principal value (non-negative real part)
--   asin/acos/atan/etc.: standard principal branches
--
-- Public surface:
--   complex.new(re, im?)            -- im defaults to 0
--   complex.polar(r, theta)         -- r*(cos+i*sin)
--   complex.i                       -- shortcut for 0+1i
--   c:abs(), c:arg(), c:conj(), c:exp(), c:log(), c:sqrt(), c:pow(z)
--   c:sin(), c:cos(), c:tan(), c:asin(), c:acos(), c:atan()
--   c:sinh(), c:cosh(), c:tanh(), c:asinh(), c:acosh(), c:atanh()
--   c:real(), c:imag()
--   Operators: + - * / ^ unary-minus ==

local M  = {}
local mt = {}

local sin, cos, tan   = math.sin, math.cos, math.tan
local sinh, cosh      = function(x) return (math.exp(x) - math.exp(-x)) * 0.5 end,
                        function(x) return (math.exp(x) + math.exp(-x)) * 0.5 end
local atan2           = math.atan2 or math.atan  -- Lua 5.3+: math.atan(y, x)
local sqrt, exp, log  = math.sqrt, math.exp, math.log
local pi              = math.pi

local function alloc(re, im)
    return setmetatable({ re = re, im = im or 0 }, mt)
end

local function is_c(x) return type(x) == "table" and getmetatable(x) == mt end

local function coerce(x)
    if is_c(x) then return x end
    if type(x) == "number" then return alloc(x, 0) end
    error("complex: cannot coerce " .. type(x))
end

function M.new(re, im) return alloc(re or 0, im or 0) end
function M.polar(r, theta) return alloc(r * cos(theta), r * sin(theta)) end
M.i = alloc(0, 1)

function M.real(c) return c.re end
function M.imag(c) return c.im end

-- ===== Basic arithmetic ================================================

function M.add(a, b)
    a, b = coerce(a), coerce(b)
    return alloc(a.re + b.re, a.im + b.im)
end

function M.sub(a, b)
    a, b = coerce(a), coerce(b)
    return alloc(a.re - b.re, a.im - b.im)
end

function M.mul(a, b)
    a, b = coerce(a), coerce(b)
    return alloc(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
end

function M.div(a, b)
    a, b = coerce(a), coerce(b)
    -- Smith's algorithm: avoid overflow when |re| ~ |im|.
    local br, bi = b.re, b.im
    local denom
    local re, im
    if math.abs(br) >= math.abs(bi) then
        local r = bi / br
        denom = br + r * bi
        re = (a.re + a.im * r) / denom
        im = (a.im - a.re * r) / denom
    else
        local r = br / bi
        denom = bi + r * br
        re = (a.re * r + a.im) / denom
        im = (a.im * r - a.re) / denom
    end
    return alloc(re, im)
end

function M.neg(a)  return alloc(-a.re, -a.im) end
function M.conj(a) return alloc(a.re, -a.im) end

function M.abs(a)
    -- hypot to avoid spurious overflow on large |re| or |im|
    local r, i = math.abs(a.re), math.abs(a.im)
    if r < i then r, i = i, r end
    if r == 0 then return 0 end
    local t = i / r
    return r * sqrt(1 + t * t)
end

function M.arg(a) return atan2(a.im, a.re) end

function M.eq(a, b)
    a, b = coerce(a), coerce(b)
    return a.re == b.re and a.im == b.im
end

-- ===== Transcendentals =================================================

function M.exp(a)
    local r = exp(a.re)
    return alloc(r * cos(a.im), r * sin(a.im))
end

function M.log(a)
    return alloc(log(M.abs(a)), atan2(a.im, a.re))
end

function M.sqrt(a)
    -- principal branch via the polar form, but using hypot for stability
    local mag = M.abs(a)
    if mag == 0 then return alloc(0, 0) end
    local s = sqrt((mag + math.abs(a.re)) * 0.5)
    if a.re >= 0 then
        return alloc(s, a.im / (2 * s))
    else
        local t = sqrt((mag - a.re) * 0.5)
        local sign_im = a.im >= 0 and 1 or -1
        return alloc(math.abs(a.im) / (2 * t), sign_im * t)
    end
end

function M.pow(a, b)
    a = coerce(a)
    -- integer fast path: real-integer exponent uses repeated squaring
    if type(b) == "number" and b == math.floor(b) and b >= 0 and b < 2^31 then
        local result = alloc(1, 0)
        local base = a
        while b > 0 do
            if b % 2 == 1 then result = M.mul(result, base) end
            b = math.floor(b / 2)
            if b > 0 then base = M.mul(base, base) end
        end
        return result
    end
    b = coerce(b)
    if a.re == 0 and a.im == 0 then
        if b.re == 0 and b.im == 0 then return alloc(1, 0) end
        return alloc(0, 0)
    end
    -- a^b = exp(b * log(a))
    return M.exp(M.mul(b, M.log(a)))
end

function M.sin(a)
    return alloc(sin(a.re) * cosh(a.im), cos(a.re) * sinh(a.im))
end

function M.cos(a)
    return alloc(cos(a.re) * cosh(a.im), -sin(a.re) * sinh(a.im))
end

function M.tan(a)
    return M.div(M.sin(a), M.cos(a))
end

function M.sinh(a)
    return alloc(sinh(a.re) * cos(a.im), cosh(a.re) * sin(a.im))
end

function M.cosh(a)
    return alloc(cosh(a.re) * cos(a.im), sinh(a.re) * sin(a.im))
end

function M.tanh(a)
    return M.div(M.sinh(a), M.cosh(a))
end

-- Inverse trigs: closed-form via log/sqrt, using the standard principal branches.

function M.asin(a)
    -- -i * log(i*z + sqrt(1 - z^2))
    local one    = alloc(1, 0)
    local iz     = alloc(-a.im, a.re)
    local root   = M.sqrt(M.sub(one, M.mul(a, a)))
    local inner  = M.add(iz, root)
    local lg     = M.log(inner)
    return alloc(lg.im, -lg.re)
end

function M.acos(a)
    -- pi/2 - asin(z)
    local s = M.asin(a)
    return alloc(pi * 0.5 - s.re, -s.im)
end

function M.atan(a)
    -- 0.5*i * (log(1 - i*z) - log(1 + i*z))
    local iz   = alloc(-a.im, a.re)
    local one  = alloc(1, 0)
    local num  = M.log(M.sub(one, iz))
    local den  = M.log(M.add(one, iz))
    local diff = M.sub(num, den)
    return alloc(-diff.im * 0.5, diff.re * 0.5)
end

function M.asinh(a)
    -- log(z + sqrt(z^2 + 1))
    local one = alloc(1, 0)
    return M.log(M.add(a, M.sqrt(M.add(M.mul(a, a), one))))
end

function M.acosh(a)
    -- log(z + sqrt(z+1) * sqrt(z-1))
    local one = alloc(1, 0)
    local s = M.mul(M.sqrt(M.add(a, one)), M.sqrt(M.sub(a, one)))
    return M.log(M.add(a, s))
end

function M.atanh(a)
    -- 0.5 * log((1+z) / (1-z))
    local one = alloc(1, 0)
    return M.mul(alloc(0.5, 0), M.log(M.div(M.add(one, a), M.sub(one, a))))
end

-- ===== Pretty-print ====================================================

function M.tostring(c)
    if c.im == 0 then return tostring(c.re) end
    if c.re == 0 then return tostring(c.im) .. "i" end
    local sign = c.im >= 0 and "+" or "-"
    return string.format("%s%s%si", tostring(c.re), sign, tostring(math.abs(c.im)))
end

function M.to_polar(c)
    -- returns (r, theta) so callers can do `r, theta = c:to_polar()`
    return M.abs(c), M.arg(c)
end

-- ===== Metatable =======================================================

mt.__index    = function(_, k) return M[k] end
mt.__add      = function(a, b) return M.add(a, b) end
mt.__sub      = function(a, b) return M.sub(a, b) end
mt.__mul      = function(a, b) return M.mul(a, b) end
mt.__div      = function(a, b) return M.div(a, b) end
mt.__pow      = function(a, b) return M.pow(a, b) end
mt.__unm      = function(a)    return M.neg(a) end
mt.__eq       = function(a, b) return M.eq(a, b) end
mt.__tostring = function(a)    return M.tostring(a) end

setmetatable(M, { __call = function(_, re, im) return M.new(re, im) end })

return M
