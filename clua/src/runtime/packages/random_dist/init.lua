-- random_dist -- sampling, PDF, CDF, and quantile for common distributions.
--
-- Two surfaces are exposed:
--
--   * Distribution-object API (preferred):
--       local d = random_dist.normal(0, 1)
--       d:sample(); d:pdf(x); d:cdf(x); d:quantile(p); d:mean(); d:variance()
--     The object carries its parameters; methods reuse the module's RNG unless
--     a per-distribution RNG was bound via random_dist.bind(d, rng).
--
--   * Module-level sampling helpers (legacy / quick draws):
--       random_dist.normal_sample(mu, sigma)  random_dist.poisson_sample(lambda)
--     These mirror the older flat API. The dist-object methods (.sample())
--     route through them, so behaviour is identical.
--
-- The internal RNG is xoshiro256** built on Lua 5.4 native bitwise ops.
-- random_dist.seed(n) reseeds the global generator; random_dist.create_rng(s)
-- returns an independent instance.
--
-- Distributions implemented:
--   continuous:   uniform, normal, exponential, gamma, beta, chi_squared,
--                 student_t, f, lognormal, weibull, pareto, cauchy
--   discrete:     poisson, binomial, geometric, bernoulli
--   multivariate: dirichlet, multivariate_normal (caller passes Cholesky factor)

local M = {}

local sqrt, log, exp, pi = math.sqrt, math.log, math.exp, math.pi
local sin, cos, floor    = math.sin, math.cos, math.floor
local abs                = math.abs

local MASK64 = 0xFFFFFFFFFFFFFFFF

-- ===== xoshiro256** RNG (Lua 5.4 native 64-bit integers) ===============

local function rotl64(x, k)
    return ((x << k) | (x >> (64 - k))) & MASK64
end

local function splitmix64(state)
    state.s = (state.s + 0x9E3779B97F4A7C15) & MASK64
    local z = state.s
    z = ((z ~ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    z = ((z ~ (z >> 27)) * 0x94D049BB133111EB) & MASK64
    z = z ~ (z >> 31)
    return z & MASK64
end

local rng_mt = {}
rng_mt.__index = rng_mt

function rng_mt:next_u64()
    local s = self.s
    local result = (rotl64((s[2] * 5) & MASK64, 7) * 9) & MASK64
    local t = (s[2] << 17) & MASK64
    s[3] = s[3] ~ s[1]
    s[4] = s[4] ~ s[2]
    s[2] = s[2] ~ s[3]
    s[1] = s[1] ~ s[4]
    s[3] = s[3] ~ t
    s[4] = rotl64(s[4], 45)
    return result
end

function rng_mt:next_double()
    -- top 53 bits (xoshiro convention) divided by 2^53
    local v = self:next_u64() >> 11
    return v * (1.0 / 9007199254740992.0)  -- 1 / 2^53
end

function rng_mt:next_int(lo, hi)
    -- inclusive lo, inclusive hi
    if hi == nil then lo, hi = 0, lo end
    if hi < lo then error("random_dist: bad int range") end
    return lo + floor(self:next_double() * (hi - lo + 1))
end

function M.create_rng(seed)
    seed = seed or os.time()
    local sm = { s = seed & MASK64 }
    -- Avoid building the array as { call(), call(), call(), call() } -- the
    -- LuaVM codegen can't handle the SETLIST varargs tail when the final
    -- expression's multi-return spills into the constructor.
    local s = { 0, 0, 0, 0 }
    s[1] = splitmix64(sm)
    s[2] = splitmix64(sm)
    s[3] = splitmix64(sm)
    s[4] = splitmix64(sm)
    -- guard against all-zero state (would lock xoshiro)
    if s[1] == 0 and s[2] == 0 and s[3] == 0 and s[4] == 0 then s[1] = 1 end
    return setmetatable({ s = s }, rng_mt)
end

local _global = M.create_rng()

local function get_rng(r) return r or _global end

function M.seed(n) _global = M.create_rng(n or os.time()) end

function M.uniform_01(rng) return get_rng(rng):next_double() end

-- ===== Lanczos lgamma (used widely below) ===============================

local _LANCZOS = {
     0.99999999999980993,
   676.5203681218851,
 -1259.1392167224028,
   771.32342877765313,
  -176.61502916214059,
    12.507343278686905,
    -0.13857109526572012,
     9.9843695780195716e-6,
     1.5056327351493116e-7,
}

local function lgamma(x)
    if x < 0.5 then
        return log(pi / sin(pi * x)) - lgamma(1 - x)
    end
    x = x - 1
    local a = _LANCZOS[1]
    local tt = x + 7 + 0.5
    for i = 2, #_LANCZOS do a = a + _LANCZOS[i] / (x + i - 1) end
    return 0.5 * log(2 * pi) + (x + 0.5) * log(tt) - tt + log(a)
end

local function gamma_fn(x) return exp(lgamma(x)) end

M.lgamma = lgamma
M.gamma_fn = gamma_fn

-- ===== Error function + normal CDF / inverse-CDF ========================

local function erf(x)
    -- Abramowitz & Stegun 7.1.26; |err| < 1.5e-7
    local sign = x < 0 and -1 or 1
    x = abs(x)
    local a1, a2, a3, a4, a5 = 0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429
    local p = 0.3275911
    local t = 1 / (1 + p * x)
    local y = 1 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * exp(-x * x)
    return sign * y
end

local function normal_cdf_unit(z)
    return 0.5 * (1 + erf(z / sqrt(2)))
end

local function inv_normal_cdf_unit(p)
    -- Beasley-Springer-Moro
    if p <= 0 or p >= 1 then
        if p == 0 then return -math.huge end
        if p == 1 then return math.huge end
        error("inv_normal_cdf: p out of (0,1)")
    end
    local a = { -3.969683028665376e+01,  2.209460984245205e+02,
                -2.759285104469687e+02,  1.383577518672690e+02,
                -3.066479806614716e+01,  2.506628277459239e+00 }
    local b = { -5.447609879822406e+01,  1.615858368580409e+02,
                -1.556989798598866e+02,  6.680131188771972e+01,
                -1.328068155288572e+01 }
    local c = { -7.784894002430293e-03, -3.223964580411365e-01,
                -2.400758277161838e+00, -2.549732539343734e+00,
                 4.374664141464968e+00,  2.938163982698783e+00 }
    local d = {  7.784695709041462e-03,  3.224671290700398e-01,
                 2.445134137142996e+00,  3.754408661907416e+00 }
    local plow, phigh = 0.02425, 1 - 0.02425
    if p < plow then
        local q = sqrt(-2 * log(p))
        return (((((c[1]*q+c[2])*q+c[3])*q+c[4])*q+c[5])*q+c[6])
             / ((((d[1]*q+d[2])*q+d[3])*q+d[4])*q+1)
    elseif p <= phigh then
        local q = p - 0.5
        local r = q * q
        return (((((a[1]*r+a[2])*r+a[3])*r+a[4])*r+a[5])*r+a[6])*q
             / (((((b[1]*r+b[2])*r+b[3])*r+b[4])*r+b[5])*r+1)
    else
        local q = sqrt(-2 * log(1 - p))
        return -(((((c[1]*q+c[2])*q+c[3])*q+c[4])*q+c[5])*q+c[6])
              / ((((d[1]*q+d[2])*q+d[3])*q+d[4])*q+1)
    end
end

M.erf = erf
M.normal_cdf_unit = normal_cdf_unit
M.inv_normal_cdf_unit = inv_normal_cdf_unit

-- ===== Regularised incomplete gamma / beta (for CDFs) ===================

local function reg_gamma_p(s, x)
    -- P(s, x) = lower incomplete gamma / gamma(s)
    if x < 0 or s <= 0 then return 0 / 0 end
    if x == 0 then return 0 end
    if x < s + 1 then
        local ap = s
        local sum_v, del = 1 / s, 1 / s
        for _ = 1, 200 do
            ap = ap + 1
            del = del * x / ap
            sum_v = sum_v + del
            if abs(del) < abs(sum_v) * 1e-15 then break end
        end
        return sum_v * exp(-x + s * log(x) - lgamma(s))
    end
    local FPMIN = 1e-300
    local b = x + 1 - s
    local c_v = 1 / FPMIN
    local d = 1 / b
    local h = d
    for i = 1, 200 do
        local an = -i * (i - s)
        b = b + 2
        d = an * d + b
        if abs(d) < FPMIN then d = FPMIN end
        c_v = b + an / c_v
        if abs(c_v) < FPMIN then c_v = FPMIN end
        d = 1 / d
        local del = d * c_v
        h = h * del
        if abs(del - 1) < 1e-15 then break end
    end
    local Q = exp(-x + s * log(x) - lgamma(s)) * h
    return 1 - Q
end

local function betacf(a, b, x)
    local FPMIN = 1e-300
    local qab = a + b
    local qap = a + 1
    local qam = a - 1
    local c_v = 1
    local d = 1 - qab * x / qap
    if abs(d) < FPMIN then d = FPMIN end
    d = 1 / d
    local h = d
    for m = 1, 200 do
        local m2 = 2 * m
        local aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1 + aa * d
        if abs(d) < FPMIN then d = FPMIN end
        c_v = 1 + aa / c_v
        if abs(c_v) < FPMIN then c_v = FPMIN end
        d = 1 / d
        h = h * d * c_v
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1 + aa * d
        if abs(d) < FPMIN then d = FPMIN end
        c_v = 1 + aa / c_v
        if abs(c_v) < FPMIN then c_v = FPMIN end
        d = 1 / d
        local del = d * c_v
        h = h * del
        if abs(del - 1) < 1e-15 then break end
    end
    return h
end

local function reg_beta(a, b, x)
    if x <= 0 then return 0 end
    if x >= 1 then return 1 end
    local bt = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x))
    if x < (a + 1) / (a + b + 2) then return bt * betacf(a, b, x) / a end
    return 1 - bt * betacf(b, a, 1 - x) / b
end

M.reg_gamma_p = reg_gamma_p
M.reg_beta    = reg_beta

-- ===== Bisection inverse for quantiles ==================================
--
-- Many distributions have no closed-form inverse-CDF. We bisect on the CDF
-- when needed; callers should not rely on bisection inside tight inner loops.

local function bisect_inv(cdf_fn, p, lo, hi, tol, max_iter)
    tol = tol or 1e-10
    max_iter = max_iter or 100
    if p <= 0 then return lo end
    if p >= 1 then return hi end
    -- Expand bracket if needed
    while cdf_fn(lo) > p do lo = lo - (hi - lo) end
    while cdf_fn(hi) < p do hi = hi + (hi - lo) end
    for _ = 1, max_iter do
        local mid = (lo + hi) * 0.5
        local c = cdf_fn(mid)
        if c < p then lo = mid else hi = mid end
        if hi - lo < tol then return (lo + hi) * 0.5 end
    end
    return (lo + hi) * 0.5
end

-- ===== Raw samplers (module-level, used by dist objects) ================

local function normal_unit(rng)
    local u1 = rng:next_double()
    local u2 = rng:next_double()
    if u1 < 1e-300 then u1 = 1e-300 end
    return sqrt(-2 * log(u1)) * cos(2 * pi * u2)
end

local function gamma_sample(shape, scale, rng)
    -- Marsaglia & Tsang; recurse for shape < 1
    if shape <= 0 then error("gamma: shape must be > 0") end
    if shape < 1 then
        local u = rng:next_double()
        return gamma_sample(shape + 1, scale, rng) * u ^ (1 / shape)
    end
    local d = shape - 1 / 3
    local c = 1 / sqrt(9 * d)
    while true do
        local x, v
        repeat
            x = normal_unit(rng)
            v = 1 + c * x
        until v > 0
        v = v * v * v
        local u = rng:next_double()
        if u < 1 - 0.0331 * x * x * x * x then return d * v * scale end
        if log(u) < 0.5 * x * x + d * (1 - v + log(v)) then return d * v * scale end
    end
end

function M.uniform_sample(a, b, rng)
    return a + (b - a) * get_rng(rng):next_double()
end

function M.normal_sample(mu, sigma, rng)
    mu = mu or 0; sigma = sigma or 1
    return mu + sigma * normal_unit(get_rng(rng))
end

function M.exponential_sample(lambda, rng)
    if lambda <= 0 then error("exponential: lambda must be > 0") end
    return -log(1 - get_rng(rng):next_double()) / lambda
end

function M.lognormal_sample(mu, sigma, rng)
    return exp(M.normal_sample(mu, sigma, rng))
end

function M.weibull_sample(k, lambda, rng)
    return lambda * (-log(1 - get_rng(rng):next_double())) ^ (1 / k)
end

function M.pareto_sample(alpha, xm, rng)
    return xm / (1 - get_rng(rng):next_double()) ^ (1 / alpha)
end

function M.cauchy_sample(x0, gamma_p, rng)
    return x0 + gamma_p * math.tan(pi * (get_rng(rng):next_double() - 0.5))
end

function M.gamma_sample(shape, scale, rng)
    return gamma_sample(shape, scale or 1, get_rng(rng))
end

function M.beta_sample(alpha, beta_p, rng)
    rng = get_rng(rng)
    local x = gamma_sample(alpha,  1, rng)
    local y = gamma_sample(beta_p, 1, rng)
    return x / (x + y)
end

function M.chi_squared_sample(k, rng)
    -- chi2(k) == gamma(k/2, 2)
    return gamma_sample(k * 0.5, 2, get_rng(rng))
end

function M.student_t_sample(df, rng)
    rng = get_rng(rng)
    -- t = Z / sqrt(V/df) with Z ~ N(0,1), V ~ chi2(df)
    local z = normal_unit(rng)
    local v = gamma_sample(df * 0.5, 2, rng)
    return z / sqrt(v / df)
end

function M.f_sample(d1, d2, rng)
    -- F = (U1/d1) / (U2/d2) with U1 ~ chi2(d1), U2 ~ chi2(d2)
    rng = get_rng(rng)
    local u1 = gamma_sample(d1 * 0.5, 2, rng)
    local u2 = gamma_sample(d2 * 0.5, 2, rng)
    return (u1 / d1) / (u2 / d2)
end

function M.poisson_sample(lambda, rng)
    rng = get_rng(rng)
    if lambda < 30 then
        local L = exp(-lambda)
        local k = 0
        local p = 1
        while true do
            k = k + 1
            p = p * rng:next_double()
            if p <= L then return k - 1 end
        end
    end
    -- Atkinson rejection for large lambda
    local c = 0.767 - 3.36 / lambda
    local beta = pi / sqrt(3 * lambda)
    local alpha = beta * lambda
    local k = log(c) - lambda - log(beta)
    while true do
        local u = rng:next_double()
        local x = (alpha - log((1 - u) / u)) / beta
        local n = floor(x + 0.5)
        if n >= 0 then
            local v = rng:next_double()
            local y = alpha - beta * x
            local lhs = y + log(v / (1 + exp(y)) ^ 2)
            local rhs = k + n * log(lambda) - lgamma(n + 1)
            if lhs <= rhs then return n end
        end
    end
end

function M.binomial_sample(n, p, rng)
    rng = get_rng(rng)
    if n * p < 30 then
        local k = 0
        for _ = 1, n do
            if rng:next_double() < p then k = k + 1 end
        end
        return k
    end
    local mu = n * p
    local sigma = sqrt(n * p * (1 - p))
    local s = floor(M.normal_sample(mu, sigma, rng) + 0.5)
    if s < 0 then return 0 end
    if s > n then return n end
    return s
end

function M.geometric_sample(p, rng)
    if p <= 0 or p > 1 then error("geometric: p must be in (0,1]") end
    return floor(log(1 - get_rng(rng):next_double()) / log(1 - p)) + 1
end

function M.bernoulli_sample(p, rng)
    return get_rng(rng):next_double() < p and 1 or 0
end

function M.dirichlet_sample(alphas, rng)
    rng = get_rng(rng)
    local k = #alphas
    local out = {}
    local s = 0
    for i = 1, k do out[i] = gamma_sample(alphas[i], 1, rng); s = s + out[i] end
    for i = 1, k do out[i] = out[i] / s end
    return out
end

function M.multivariate_normal_sample(mean, cov_chol, rng)
    rng = get_rng(rng)
    local n = #mean
    local z = {}
    for i = 1, n do z[i] = normal_unit(rng) end
    local out = {}
    for i = 1, n do
        local s = 0
        for j = 1, i do s = s + cov_chol[(i - 1) * n + j] * z[j] end
        out[i] = mean[i] + s
    end
    return out
end

-- ===== Distribution objects =============================================
--
-- Each dist object is a tiny table: { kind = ..., params... } with a metatable
-- carrying :sample/:pdf/:cdf/:quantile/:mean/:variance methods.

local function make_dist(kind, params)
    local d = { kind = kind }
    for k, v in pairs(params) do d[k] = v end
    return d
end

local _dist_mt = {}
_dist_mt.__index = _dist_mt

local function bind_meta(t)
    return setmetatable(t, _dist_mt)
end

-- ----- Uniform ----------------------------------------------------------

function M.uniform(a, b)
    a = a or 0; b = b or 1
    return bind_meta(make_dist("uniform", { a = a, b = b }))
end

-- ----- Normal -----------------------------------------------------------

function M.normal(mu, sigma)
    mu = mu or 0; sigma = sigma or 1
    return bind_meta(make_dist("normal", { mu = mu, sigma = sigma }))
end

-- ----- Exponential ------------------------------------------------------

function M.exponential(lambda)
    lambda = lambda or 1
    return bind_meta(make_dist("exponential", { lambda = lambda }))
end

-- ----- Gamma ------------------------------------------------------------

function M.gamma(shape, scale)
    scale = scale or 1
    return bind_meta(make_dist("gamma", { shape = shape, scale = scale }))
end

-- ----- Beta -------------------------------------------------------------

function M.beta(alpha, beta_p)
    return bind_meta(make_dist("beta", { alpha = alpha, beta = beta_p }))
end

-- ----- Chi-squared ------------------------------------------------------

function M.chi_squared(k)
    return bind_meta(make_dist("chi_squared", { k = k }))
end

-- ----- Student-t --------------------------------------------------------

function M.student_t(df)
    return bind_meta(make_dist("student_t", { df = df }))
end

-- ----- F ----------------------------------------------------------------

function M.f(d1, d2)
    return bind_meta(make_dist("f", { d1 = d1, d2 = d2 }))
end

-- ----- Lognormal --------------------------------------------------------

function M.lognormal(mu, sigma)
    mu = mu or 0; sigma = sigma or 1
    return bind_meta(make_dist("lognormal", { mu = mu, sigma = sigma }))
end

-- ----- Weibull ----------------------------------------------------------

function M.weibull(k, lambda)
    lambda = lambda or 1
    return bind_meta(make_dist("weibull", { k = k, lambda = lambda }))
end

-- ----- Pareto -----------------------------------------------------------

function M.pareto(alpha, xm)
    xm = xm or 1
    return bind_meta(make_dist("pareto", { alpha = alpha, xm = xm }))
end

-- ----- Cauchy -----------------------------------------------------------

function M.cauchy(x0, gamma_p)
    x0 = x0 or 0; gamma_p = gamma_p or 1
    return bind_meta(make_dist("cauchy", { x0 = x0, gamma = gamma_p }))
end

-- ----- Poisson ----------------------------------------------------------

function M.poisson(lambda)
    return bind_meta(make_dist("poisson", { lambda = lambda }))
end

-- ----- Binomial ---------------------------------------------------------

function M.binomial(n, p)
    return bind_meta(make_dist("binomial", { n = n, p = p }))
end

-- ----- Geometric --------------------------------------------------------

function M.geometric(p)
    return bind_meta(make_dist("geometric", { p = p }))
end

-- ----- Bernoulli --------------------------------------------------------

function M.bernoulli(p)
    return bind_meta(make_dist("bernoulli", { p = p }))
end

-- ===== Method dispatch on dist objects ==================================
--
-- The methods are dispatched on d.kind. Centralising this keeps the per-
-- distribution constructors tiny and lets us add a new dist by editing a
-- single table per method.

local _SAMPLE = {
    uniform     = function(d, r) return M.uniform_sample(d.a, d.b, r) end,
    normal      = function(d, r) return M.normal_sample(d.mu, d.sigma, r) end,
    exponential = function(d, r) return M.exponential_sample(d.lambda, r) end,
    gamma       = function(d, r) return M.gamma_sample(d.shape, d.scale, r) end,
    beta        = function(d, r) return M.beta_sample(d.alpha, d.beta, r) end,
    chi_squared = function(d, r) return M.chi_squared_sample(d.k, r) end,
    student_t   = function(d, r) return M.student_t_sample(d.df, r) end,
    f           = function(d, r) return M.f_sample(d.d1, d.d2, r) end,
    lognormal   = function(d, r) return M.lognormal_sample(d.mu, d.sigma, r) end,
    weibull     = function(d, r) return M.weibull_sample(d.k, d.lambda, r) end,
    pareto      = function(d, r) return M.pareto_sample(d.alpha, d.xm, r) end,
    cauchy      = function(d, r) return M.cauchy_sample(d.x0, d.gamma, r) end,
    poisson     = function(d, r) return M.poisson_sample(d.lambda, r) end,
    binomial    = function(d, r) return M.binomial_sample(d.n, d.p, r) end,
    geometric   = function(d, r) return M.geometric_sample(d.p, r) end,
    bernoulli   = function(d, r) return M.bernoulli_sample(d.p, r) end,
}

local _MEAN = {
    uniform     = function(d) return (d.a + d.b) * 0.5 end,
    normal      = function(d) return d.mu end,
    exponential = function(d) return 1 / d.lambda end,
    gamma       = function(d) return d.shape * d.scale end,
    beta        = function(d) return d.alpha / (d.alpha + d.beta) end,
    chi_squared = function(d) return d.k end,
    student_t   = function(d) if d.df > 1 then return 0 end return 0 / 0 end,
    f           = function(d) if d.d2 > 2 then return d.d2 / (d.d2 - 2) end return 0 / 0 end,
    lognormal   = function(d) return exp(d.mu + d.sigma * d.sigma * 0.5) end,
    weibull     = function(d) return d.lambda * gamma_fn(1 + 1 / d.k) end,
    pareto      = function(d) if d.alpha > 1 then return d.alpha * d.xm / (d.alpha - 1) end return math.huge end,
    cauchy      = function() return 0 / 0 end,  -- undefined
    poisson     = function(d) return d.lambda end,
    binomial    = function(d) return d.n * d.p end,
    geometric   = function(d) return 1 / d.p end,
    bernoulli   = function(d) return d.p end,
}

local _VAR = {
    uniform     = function(d) return (d.b - d.a) ^ 2 / 12 end,
    normal      = function(d) return d.sigma * d.sigma end,
    exponential = function(d) return 1 / (d.lambda * d.lambda) end,
    gamma       = function(d) return d.shape * d.scale * d.scale end,
    beta        = function(d) local s = d.alpha + d.beta; return d.alpha * d.beta / (s * s * (s + 1)) end,
    chi_squared = function(d) return 2 * d.k end,
    student_t   = function(d) if d.df > 2 then return d.df / (d.df - 2) end return 0 / 0 end,
    f           = function(d)
        if d.d2 <= 4 then return 0 / 0 end
        return 2 * d.d2 * d.d2 * (d.d1 + d.d2 - 2)
             / (d.d1 * (d.d2 - 2) ^ 2 * (d.d2 - 4))
    end,
    lognormal   = function(d) local s2 = d.sigma * d.sigma; return (exp(s2) - 1) * exp(2 * d.mu + s2) end,
    weibull     = function(d) local g1 = gamma_fn(1 + 1 / d.k); local g2 = gamma_fn(1 + 2 / d.k)
                              return d.lambda * d.lambda * (g2 - g1 * g1) end,
    pareto      = function(d)
        if d.alpha > 2 then return (d.xm * d.xm * d.alpha) / ((d.alpha - 1) ^ 2 * (d.alpha - 2)) end
        return math.huge
    end,
    cauchy      = function() return 0 / 0 end,
    poisson     = function(d) return d.lambda end,
    binomial    = function(d) return d.n * d.p * (1 - d.p) end,
    geometric   = function(d) return (1 - d.p) / (d.p * d.p) end,
    bernoulli   = function(d) return d.p * (1 - d.p) end,
}

local _PDF = {
    uniform = function(d, x)
        if x < d.a or x > d.b then return 0 end
        return 1 / (d.b - d.a)
    end,
    normal = function(d, x)
        local z = (x - d.mu) / d.sigma
        return exp(-0.5 * z * z) / (d.sigma * sqrt(2 * pi))
    end,
    exponential = function(d, x)
        if x < 0 then return 0 end
        return d.lambda * exp(-d.lambda * x)
    end,
    gamma = function(d, x)
        if x <= 0 then return 0 end
        local k, theta = d.shape, d.scale
        return exp((k - 1) * log(x) - x / theta - k * log(theta) - lgamma(k))
    end,
    beta = function(d, x)
        if x <= 0 or x >= 1 then return 0 end
        local a, b = d.alpha, d.beta
        return exp((a - 1) * log(x) + (b - 1) * log(1 - x)
                 + lgamma(a + b) - lgamma(a) - lgamma(b))
    end,
    chi_squared = function(d, x)
        if x <= 0 then return 0 end
        local k = d.k
        return exp((k * 0.5 - 1) * log(x) - x * 0.5 - (k * 0.5) * log(2) - lgamma(k * 0.5))
    end,
    student_t = function(d, x)
        local df = d.df
        local num = lgamma((df + 1) * 0.5) - lgamma(df * 0.5)
        return exp(num) / (sqrt(df * pi) * (1 + x * x / df) ^ ((df + 1) * 0.5))
    end,
    f = function(d, x)
        if x <= 0 then return 0 end
        local d1, d2 = d.d1, d.d2
        local num = lgamma((d1 + d2) * 0.5) - lgamma(d1 * 0.5) - lgamma(d2 * 0.5)
        return exp(num + (d1 * 0.5) * log(d1 / d2)
                       + (d1 * 0.5 - 1) * log(x)
                       - ((d1 + d2) * 0.5) * log(1 + d1 * x / d2))
    end,
    lognormal = function(d, x)
        if x <= 0 then return 0 end
        local lx = log(x)
        return exp(-((lx - d.mu) ^ 2) / (2 * d.sigma * d.sigma))
             / (x * d.sigma * sqrt(2 * pi))
    end,
    weibull = function(d, x)
        if x < 0 then return 0 end
        local k, lam = d.k, d.lambda
        return (k / lam) * (x / lam) ^ (k - 1) * exp(-(x / lam) ^ k)
    end,
    pareto = function(d, x)
        if x < d.xm then return 0 end
        return d.alpha * d.xm ^ d.alpha / x ^ (d.alpha + 1)
    end,
    cauchy = function(d, x)
        return 1 / (pi * d.gamma * (1 + ((x - d.x0) / d.gamma) ^ 2))
    end,
    poisson = function(d, k)
        if k < 0 or k ~= floor(k) then return 0 end
        return exp(k * log(d.lambda) - d.lambda - lgamma(k + 1))
    end,
    binomial = function(d, k)
        if k < 0 or k > d.n or k ~= floor(k) then return 0 end
        local ln_c = lgamma(d.n + 1) - lgamma(k + 1) - lgamma(d.n - k + 1)
        return exp(ln_c + k * log(d.p) + (d.n - k) * log(1 - d.p))
    end,
    geometric = function(d, k)
        if k < 1 or k ~= floor(k) then return 0 end
        return d.p * (1 - d.p) ^ (k - 1)
    end,
    bernoulli = function(d, k)
        if k == 0 then return 1 - d.p end
        if k == 1 then return d.p end
        return 0
    end,
}

local _CDF = {
    uniform = function(d, x)
        if x < d.a then return 0 end
        if x > d.b then return 1 end
        return (x - d.a) / (d.b - d.a)
    end,
    normal = function(d, x)
        return normal_cdf_unit((x - d.mu) / d.sigma)
    end,
    exponential = function(d, x)
        if x < 0 then return 0 end
        return 1 - exp(-d.lambda * x)
    end,
    gamma = function(d, x)
        if x <= 0 then return 0 end
        return reg_gamma_p(d.shape, x / d.scale)
    end,
    beta = function(d, x)
        return reg_beta(d.alpha, d.beta, x)
    end,
    chi_squared = function(d, x)
        return reg_gamma_p(d.k * 0.5, x * 0.5)
    end,
    student_t = function(d, x)
        local df = d.df
        local v = df / (df + x * x)
        local p = 0.5 * reg_beta(df * 0.5, 0.5, v)
        return x > 0 and (1 - p) or p
    end,
    f = function(d, x)
        if x <= 0 then return 0 end
        return reg_beta(d.d1 * 0.5, d.d2 * 0.5, (d.d1 * x) / (d.d1 * x + d.d2))
    end,
    lognormal = function(d, x)
        if x <= 0 then return 0 end
        return normal_cdf_unit((log(x) - d.mu) / d.sigma)
    end,
    weibull = function(d, x)
        if x < 0 then return 0 end
        return 1 - exp(-(x / d.lambda) ^ d.k)
    end,
    pareto = function(d, x)
        if x < d.xm then return 0 end
        return 1 - (d.xm / x) ^ d.alpha
    end,
    cauchy = function(d, x)
        return 0.5 + math.atan((x - d.x0) / d.gamma) / pi
    end,
    poisson = function(d, k)
        if k < 0 then return 0 end
        return 1 - reg_gamma_p(floor(k) + 1, d.lambda)
    end,
    binomial = function(d, k)
        if k < 0 then return 0 end
        if k >= d.n then return 1 end
        return reg_beta(d.n - floor(k), floor(k) + 1, 1 - d.p)
    end,
    geometric = function(d, k)
        if k < 1 then return 0 end
        return 1 - (1 - d.p) ^ floor(k)
    end,
    bernoulli = function(d, k)
        if k < 0 then return 0 end
        if k < 1 then return 1 - d.p end
        return 1
    end,
}

local _QUANTILE = {
    uniform = function(d, p) return d.a + p * (d.b - d.a) end,
    normal  = function(d, p) return d.mu + d.sigma * inv_normal_cdf_unit(p) end,
    exponential = function(d, p) return -log(1 - p) / d.lambda end,
    lognormal = function(d, p) return exp(d.mu + d.sigma * inv_normal_cdf_unit(p)) end,
    weibull = function(d, p) return d.lambda * (-log(1 - p)) ^ (1 / d.k) end,
    pareto  = function(d, p) return d.xm / (1 - p) ^ (1 / d.alpha) end,
    cauchy  = function(d, p) return d.x0 + d.gamma * math.tan(pi * (p - 0.5)) end,
    -- Bisection for distributions without an analytic inverse-CDF
    gamma       = function(d, p) return bisect_inv(function(x) return _CDF.gamma(d, x) end, p, 0, d.shape * d.scale * 50) end,
    beta        = function(d, p) return bisect_inv(function(x) return _CDF.beta(d, x) end, p, 0, 1) end,
    chi_squared = function(d, p) return bisect_inv(function(x) return _CDF.chi_squared(d, x) end, p, 0, d.k * 50) end,
    student_t   = function(d, p) return bisect_inv(function(x) return _CDF.student_t(d, x) end, p, -100, 100) end,
    f           = function(d, p) return bisect_inv(function(x) return _CDF.f(d, x) end, p, 0, 100) end,
    -- discrete -- invert via summation
    poisson = function(d, p)
        local k = 0
        local cdf = exp(-d.lambda)
        local term = cdf
        while cdf < p do
            k = k + 1
            term = term * d.lambda / k
            cdf = cdf + term
            if k > 10000 then break end
        end
        return k
    end,
    binomial = function(d, p)
        local k = 0
        while k <= d.n and _CDF.binomial(d, k) < p do k = k + 1 end
        return k
    end,
    geometric = function(d, p) return math.ceil(log(1 - p) / log(1 - d.p)) end,
    bernoulli = function(d, p) return p > 1 - d.p and 1 or 0 end,
}

function _dist_mt:sample(rng)
    local fn = _SAMPLE[self.kind]
    if not fn then error("random_dist: no sampler for " .. self.kind) end
    return fn(self, get_rng(rng or self._rng))
end

function _dist_mt:samples(n, rng)
    local out = {}
    local fn = _SAMPLE[self.kind]
    rng = get_rng(rng or self._rng)
    for i = 1, n do out[i] = fn(self, rng) end
    return out
end

function _dist_mt:pdf(x)
    local fn = _PDF[self.kind]
    if not fn then error("random_dist: no PDF for " .. self.kind) end
    return fn(self, x)
end

_dist_mt.pmf = _dist_mt.pdf  -- alias for discrete dists

function _dist_mt:cdf(x)
    local fn = _CDF[self.kind]
    if not fn then error("random_dist: no CDF for " .. self.kind) end
    return fn(self, x)
end

function _dist_mt:quantile(p)
    local fn = _QUANTILE[self.kind]
    if not fn then error("random_dist: no quantile for " .. self.kind) end
    return fn(self, p)
end

function _dist_mt:mean()     return _MEAN[self.kind](self) end
function _dist_mt:variance() return _VAR[self.kind](self) end
function _dist_mt:stddev()   return sqrt(self:variance()) end

function _dist_mt:bind(rng)
    self._rng = rng
    return self
end

M.bind = function(d, rng) return d:bind(rng) end

return M
