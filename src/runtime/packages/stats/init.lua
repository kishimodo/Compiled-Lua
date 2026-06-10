-- stats -- descriptive statistics, distributions, hypothesis tests.
--
-- All inputs are plain Lua tables of numbers. Functions return numbers or
-- small tables (named fields) -- never modify the input.
--
-- Numerical approximations used:
--   erf / erfc           -- Abramowitz & Stegun 7.1.26 (max error 1.5e-7)
--   normal_cdf / inv_cdf -- via erf / Beasley-Springer-Moro
--   t-distribution CDF   -- incomplete beta via continued fraction
--   chi-square CDF       -- regularised incomplete gamma (series + cf)
--   F-distribution CDF   -- incomplete beta
-- These are accurate to ~6 significant digits for typical input ranges; the
-- module is fine for engineering work but not metrology-grade.

local M = {}

local sqrt, log, exp, pi = math.sqrt, math.log, math.exp, math.pi

-- ===== Helpers =========================================================

local function copy_sorted(t)
    local out = {}
    for i = 1, #t do out[i] = t[i] end
    table.sort(out)
    return out
end

local function sum(t)
    local s = 0
    for i = 1, #t do s = s + t[i] end
    return s
end

-- ===== Descriptive =====================================================

function M.mean(t)
    if #t == 0 then return 0 / 0 end
    return sum(t) / #t
end

function M.median(t)
    if #t == 0 then return 0 / 0 end
    local s = copy_sorted(t)
    local n = #s
    if n % 2 == 1 then return s[(n + 1) / 2] end
    return (s[n / 2] + s[n / 2 + 1]) * 0.5
end

function M.mode(t)
    if #t == 0 then return nil end
    -- returns the most frequent value (lowest if tied); also returns count
    local counts = {}
    for i = 1, #t do counts[t[i]] = (counts[t[i]] or 0) + 1 end
    local best, best_count = nil, 0
    for v, c in pairs(counts) do
        if c > best_count or (c == best_count and (best == nil or v < best)) then
            best, best_count = v, c
        end
    end
    return best, best_count
end

function M.min(t)
    if #t == 0 then return 0 / 0 end
    local m = t[1]
    for i = 2, #t do if t[i] < m then m = t[i] end end
    return m
end

function M.max(t)
    if #t == 0 then return 0 / 0 end
    local m = t[1]
    for i = 2, #t do if t[i] > m then m = t[i] end end
    return m
end

function M.range(t) return M.max(t) - M.min(t) end

function M.variance(t, population)
    -- sample variance by default (n-1); population variance with n
    local n = #t
    if n < 2 then return 0 / 0 end
    local m = M.mean(t)
    local s = 0
    for i = 1, n do local d = t[i] - m; s = s + d * d end
    return s / (population and n or (n - 1))
end

function M.stdev(t, population) return sqrt(M.variance(t, population)) end
M.stddev = M.stdev  -- spec-friendly alias

function M.sem(t)
    -- standard error of the mean
    return M.stdev(t) / sqrt(#t)
end

function M.quantile(t, q)
    -- linear-interpolation quantile (type 7 in R)
    if #t == 0 then return 0 / 0 end
    if q < 0 or q > 1 then error("stats.quantile: q must be in [0,1]") end
    local s = copy_sorted(t)
    local n = #s
    local h = (n - 1) * q + 1
    local lo = math.floor(h)
    local hi = math.ceil(h)
    if lo == hi then return s[lo] end
    return s[lo] + (h - lo) * (s[hi] - s[lo])
end

function M.percentile(t, p) return M.quantile(t, p / 100) end

function M.quartiles(t)
    return M.quantile(t, 0.25), M.quantile(t, 0.5), M.quantile(t, 0.75)
end

function M.quantiles(t, q_list)
    -- batch helper: takes a list of probabilities, returns array of quantiles
    local out = {}
    for i = 1, #q_list do out[i] = M.quantile(t, q_list[i]) end
    return out
end

function M.iqr(t)
    return M.quantile(t, 0.75) - M.quantile(t, 0.25)
end

function M.skewness(t)
    -- Fisher-Pearson (adjusted) skewness coefficient
    local n = #t
    if n < 3 then return 0 / 0 end
    local m = M.mean(t)
    local s2, s3 = 0, 0
    for i = 1, n do
        local d = t[i] - m
        s2 = s2 + d * d
        s3 = s3 + d * d * d
    end
    local var = s2 / (n - 1)
    local s = sqrt(var)
    return (n / ((n - 1) * (n - 2))) * (s3 / (s * s * s))
end

function M.kurtosis(t, excess)
    -- excess kurtosis by default (Fisher's definition)
    local n = #t
    if n < 4 then return 0 / 0 end
    local m = M.mean(t)
    local s2, s4 = 0, 0
    for i = 1, n do
        local d = t[i] - m
        s2 = s2 + d * d
        s4 = s4 + d * d * d * d
    end
    local var = s2 / n
    local k = s4 / (n * var * var)
    if excess == false then return k end
    return k - 3
end

function M.covariance(a, b, population)
    if #a ~= #b then error("stats.covariance: length mismatch") end
    local n = #a
    if n < 2 then return 0 / 0 end
    local ma, mb = M.mean(a), M.mean(b)
    local s = 0
    for i = 1, n do s = s + (a[i] - ma) * (b[i] - mb) end
    return s / (population and n or (n - 1))
end

function M.correlation(a, b)
    -- Pearson
    return M.covariance(a, b) / (M.stdev(a) * M.stdev(b))
end

M.pearson = M.correlation

function M.spearman(a, b)
    -- Spearman rank correlation: Pearson on ranks
    if #a ~= #b then error("stats.spearman: length mismatch") end
    local function ranks(t)
        local n = #t
        local pairs_t = {}
        for i = 1, n do pairs_t[i] = { v = t[i], i = i } end
        table.sort(pairs_t, function(x, y) return x.v < y.v end)
        local r = {}
        local i = 1
        while i <= n do
            local j = i
            while j < n and pairs_t[j + 1].v == pairs_t[i].v do j = j + 1 end
            -- average rank for ties
            local avg = (i + j) * 0.5
            for k = i, j do r[pairs_t[k].i] = avg end
            i = j + 1
        end
        return r
    end
    local ra, rb = ranks(a), ranks(b)
    return M.correlation(ra, rb)
end

-- ===== Special functions (approximations) ==============================

local function erf(x)
    -- A&S 7.1.26; max abs error ~1.5e-7
    local a1 =  0.254829592
    local a2 = -0.284496736
    local a3 =  1.421413741
    local a4 = -1.453152027
    local a5 =  1.061405429
    local p  =  0.3275911
    local sign = x < 0 and -1 or 1
    x = math.abs(x)
    local t = 1 / (1 + p * x)
    local y = 1 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * exp(-x * x)
    return sign * y
end

local function normal_cdf(z)
    return 0.5 * (1 + erf(z / sqrt(2)))
end
M.normal_cdf = normal_cdf
M.erf = erf

local function ln_gamma(x)
    -- Lanczos approximation, sufficient for our test statistics
    local g = 7
    local coefs = {
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
    if x < 0.5 then
        -- reflection
        return log(pi / math.sin(pi * x)) - ln_gamma(1 - x)
    end
    x = x - 1
    local a = coefs[1]
    local tt = x + g + 0.5
    for i = 2, #coefs do a = a + coefs[i] / (x + i - 1) end
    return 0.5 * log(2 * pi) + (x + 0.5) * log(tt) - tt + log(a)
end
M.ln_gamma = ln_gamma

local function regularized_gamma_p(s, x)
    -- P(s, x): lower incomplete gamma regularised
    if x < 0 or s <= 0 then return 0 / 0 end
    if x == 0 then return 0 end
    if x < s + 1 then
        -- power series
        local ap = s
        local sum_v, del = 1 / s, 1 / s
        for _ = 1, 200 do
            ap = ap + 1
            del = del * x / ap
            sum_v = sum_v + del
            if math.abs(del) < math.abs(sum_v) * 1e-15 then break end
        end
        return sum_v * exp(-x + s * log(x) - ln_gamma(s))
    end
    -- continued fraction for Q, then return 1 - Q
    local FPMIN = 1e-300
    local b = x + 1 - s
    local c_v = 1 / FPMIN
    local d = 1 / b
    local h = d
    for i = 1, 200 do
        local an = -i * (i - s)
        b = b + 2
        d = an * d + b
        if math.abs(d) < FPMIN then d = FPMIN end
        c_v = b + an / c_v
        if math.abs(c_v) < FPMIN then c_v = FPMIN end
        d = 1 / d
        local del = d * c_v
        h = h * del
        if math.abs(del - 1) < 1e-15 then break end
    end
    local Q = exp(-x + s * log(x) - ln_gamma(s)) * h
    return 1 - Q
end
M.gamma_p = regularized_gamma_p

local function regularized_beta(a, b, x)
    -- I_x(a, b)
    if x <= 0 then return 0 end
    if x >= 1 then return 1 end
    -- continued fraction (Numerical Recipes form)
    local function betacf(a, b, x)
        local FPMIN = 1e-300
        local qab = a + b
        local qap = a + 1
        local qam = a - 1
        local c_v = 1
        local d = 1 - qab * x / qap
        if math.abs(d) < FPMIN then d = FPMIN end
        d = 1 / d
        local h = d
        for m = 1, 200 do
            local m2 = 2 * m
            local aa = m * (b - m) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if math.abs(d) < FPMIN then d = FPMIN end
            c_v = 1 + aa / c_v
            if math.abs(c_v) < FPMIN then c_v = FPMIN end
            d = 1 / d
            h = h * d * c_v
            aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if math.abs(d) < FPMIN then d = FPMIN end
            c_v = 1 + aa / c_v
            if math.abs(c_v) < FPMIN then c_v = FPMIN end
            d = 1 / d
            local del = d * c_v
            h = h * del
            if math.abs(del - 1) < 1e-15 then break end
        end
        return h
    end
    local bt = exp(ln_gamma(a + b) - ln_gamma(a) - ln_gamma(b) + a * log(x) + b * log(1 - x))
    if x < (a + 1) / (a + b + 2) then
        return bt * betacf(a, b, x) / a
    end
    return 1 - bt * betacf(b, a, 1 - x) / b
end
M.beta_i = regularized_beta

-- ===== Distribution CDFs ===============================================

function M.t_cdf(t_stat, df)
    -- 1 - 0.5 * I_{df/(df+t^2)}(df/2, 1/2), with sign
    local x = df / (df + t_stat * t_stat)
    local p = 0.5 * regularized_beta(df * 0.5, 0.5, x)
    return t_stat > 0 and (1 - p) or p
end

function M.chisq_cdf(x, df)
    return regularized_gamma_p(df * 0.5, x * 0.5)
end

function M.f_cdf(x, d1, d2)
    if x <= 0 then return 0 end
    return regularized_beta(d1 * 0.5, d2 * 0.5, (d1 * x) / (d1 * x + d2))
end

-- Two-sided p-value helpers used by tests
local function t_pvalue(t_stat, df)
    return 2 * (1 - M.t_cdf(math.abs(t_stat), df))
end

-- ===== Tests ===========================================================

function M.t_test_one_sample(t, mu0)
    -- H0: mean(t) == mu0
    local n = #t
    if n < 2 then error("t_test_one_sample: need n >= 2") end
    local m = M.mean(t)
    local s = M.stdev(t)
    local se = s / sqrt(n)
    local t_stat = (m - mu0) / se
    local df = n - 1
    return {
        t = t_stat, df = df,
        p_value = t_pvalue(t_stat, df),
        mean = m, sem = se,
    }
end

function M.t_test_two_sample(a, b, equal_var)
    -- Default Welch's t-test (unequal variances). equal_var=true gives pooled.
    if equal_var == nil then equal_var = false end
    local na, nb = #a, #b
    if na < 2 or nb < 2 then error("t_test_two_sample: need n >= 2 per group") end
    local ma, mb = M.mean(a), M.mean(b)
    local va, vb = M.variance(a), M.variance(b)
    local t_stat, df
    if equal_var then
        local sp2 = ((na - 1) * va + (nb - 1) * vb) / (na + nb - 2)
        t_stat = (ma - mb) / sqrt(sp2 * (1 / na + 1 / nb))
        df = na + nb - 2
    else
        local se2 = va / na + vb / nb
        t_stat = (ma - mb) / sqrt(se2)
        -- Welch-Satterthwaite df approximation
        df = (se2 * se2) / ((va / na) ^ 2 / (na - 1) + (vb / nb) ^ 2 / (nb - 1))
    end
    return {
        t = t_stat, df = df,
        p_value = t_pvalue(t_stat, df),
        mean_a = ma, mean_b = mb,
    }
end

function M.t_test_paired(a, b)
    if #a ~= #b then error("t_test_paired: length mismatch") end
    local d = {}
    for i = 1, #a do d[i] = a[i] - b[i] end
    return M.t_test_one_sample(d, 0)
end

function M.chi_square(observed, expected)
    -- goodness-of-fit; expected can be omitted to test equal-frequency H0
    if expected == nil then
        local s = sum(observed)
        local k = #observed
        expected = {}
        for i = 1, k do expected[i] = s / k end
    end
    if #observed ~= #expected then error("chi_square: length mismatch") end
    local chi2 = 0
    for i = 1, #observed do
        local diff = observed[i] - expected[i]
        chi2 = chi2 + diff * diff / expected[i]
    end
    local df = #observed - 1
    return {
        chi2 = chi2, df = df,
        p_value = 1 - M.chisq_cdf(chi2, df),
    }
end

function M.anova_oneway(groups)
    -- groups = array of arrays of numbers
    local k = #groups
    if k < 2 then error("anova_oneway: need >= 2 groups") end
    local N = 0
    local grand = 0
    for i = 1, k do
        N = N + #groups[i]
        grand = grand + sum(groups[i])
    end
    grand = grand / N
    local SSB, SSW = 0, 0
    for i = 1, k do
        local g = groups[i]
        local mg = M.mean(g)
        SSB = SSB + #g * (mg - grand) ^ 2
        for j = 1, #g do SSW = SSW + (g[j] - mg) ^ 2 end
    end
    local dfB = k - 1
    local dfW = N - k
    local MSB = SSB / dfB
    local MSW = SSW / dfW
    local F = MSB / MSW
    return {
        F = F, df_between = dfB, df_within = dfW,
        p_value = 1 - M.f_cdf(F, dfB, dfW),
        SSB = SSB, SSW = SSW,
    }
end

function M.mann_whitney_u(a, b)
    -- two-sided large-sample normal approximation; suitable for n >= 8 per group
    local na, nb = #a, #b
    local combined = {}
    for i = 1, na do combined[#combined + 1] = { v = a[i], g = 1 } end
    for i = 1, nb do combined[#combined + 1] = { v = b[i], g = 2 } end
    table.sort(combined, function(x, y) return x.v < y.v end)
    local n = #combined
    -- assign average ranks with tie correction
    local i = 1
    local rank_a = 0
    local tie_corr = 0
    while i <= n do
        local j = i
        while j < n and combined[j + 1].v == combined[i].v do j = j + 1 end
        local avg_rank = (i + j) * 0.5
        local tlen = j - i + 1
        if tlen > 1 then tie_corr = tie_corr + (tlen * tlen * tlen - tlen) end
        for k = i, j do
            if combined[k].g == 1 then rank_a = rank_a + avg_rank end
        end
        i = j + 1
    end
    local U1 = rank_a - na * (na + 1) * 0.5
    local U2 = na * nb - U1
    local U = U1 < U2 and U1 or U2
    local mean_U = na * nb / 2
    local sd_U = sqrt((na * nb / 12) * (n + 1 - tie_corr / (n * (n - 1))))
    local z = (U - mean_U) / sd_U
    return {
        U = U, U1 = U1, U2 = U2, z = z,
        p_value = 2 * (1 - normal_cdf(math.abs(z))),
    }
end

-- ===== Histogram =======================================================

function M.histogram(t, bins)
    -- bins: number (compute edges) OR array of edges
    if #t == 0 then error("stats.histogram: empty data") end
    local edges
    if type(bins) == "number" or bins == nil then
        local k = bins or 10
        local lo, hi = M.min(t), M.max(t)
        if lo == hi then hi = lo + 1 end
        local step = (hi - lo) / k
        edges = {}
        for i = 0, k do edges[i + 1] = lo + i * step end
    else
        edges = bins
    end
    local k = #edges - 1
    local counts = {}
    for i = 1, k do counts[i] = 0 end
    for i = 1, #t do
        local v = t[i]
        -- binary search for bin
        local lo, hi = 1, k
        while lo <= hi do
            local mid = math.floor((lo + hi) * 0.5)
            if v < edges[mid] then hi = mid - 1
            elseif v >= edges[mid + 1] and mid < k then lo = mid + 1
            else lo = mid; break end
        end
        if v >= edges[1] and v <= edges[k + 1] then
            counts[math.max(1, math.min(k, lo))] = counts[math.max(1, math.min(k, lo))] + 1
        end
    end
    return { edges = edges, counts = counts }
end

M.mann_whitney = M.mann_whitney_u

-- ===== Umbrella t_test ==================================================
--
-- Dispatches to one-sample / paired / two-sample based on opts. Keeps the
-- spec's t_test(a, b, opts) shape callable.

local function apply_one_sided(res, opts)
    -- Convert the two-sided p_value in res to a one-sided one when requested.
    -- The one-sided p depends on the alternative AND the sign of the statistic;
    -- it is NOT simply two_sided/2 (that only holds when t is on the
    -- alternative's side). t_cdf(t) is P(T <= t).
    if opts.tail ~= "one" and opts.alternative ~= "greater" and opts.alternative ~= "less" then
        return
    end
    local cdf = M.t_cdf(res.t, res.df)
    -- "less" -> H1: statistic small/negative -> p = P(T <= t) = t_cdf(t)
    -- default one-sided when not "less" is "greater" -> p = P(T >= t)
    if opts.alternative == "less" then
        res.p_value = cdf
    else
        res.p_value = 1 - cdf
    end
end

function M.t_test(a, b, opts)
    opts = opts or {}
    -- one-sample: caller passed (sample, mu0)
    if type(b) == "number" then
        local res = M.t_test_one_sample(a, b)
        apply_one_sided(res, opts)
        return res
    end
    -- table b: paired or two-sample
    local res
    if opts.paired then
        res = M.t_test_paired(a, b)
    else
        res = M.t_test_two_sample(a, b, opts.equal_var)
    end
    apply_one_sided(res, opts)
    return res
end

-- ===== Kolmogorov-Smirnov test ==========================================
--
-- One-sample and two-sample variants. The asymptotic p-value uses the
-- Kolmogorov distribution series; accurate enough for n >= ~20.

local function ks_pvalue(d, n_eff)
    -- Smirnov's series for the limiting distribution of sqrt(n)*D
    local lambda = (sqrt(n_eff) + 0.12 + 0.11 / sqrt(n_eff)) * d
    local sum_v = 0
    for j = 1, 100 do
        local term = 2 * (-1) ^ (j - 1) * exp(-2 * j * j * lambda * lambda)
        sum_v = sum_v + term
        if math.abs(term) < 1e-12 * math.abs(sum_v) then break end
    end
    if sum_v < 0 then sum_v = 0 end
    if sum_v > 1 then sum_v = 1 end
    return sum_v
end

function M.ks_test(a, b)
    -- Two-sample KS test: computes the maximum gap between the two empirical
    -- CDFs. If b is a function, treats it as a CDF for one-sample testing.
    if type(b) == "function" then
        -- one-sample: max |F_n(x) - F(x)| over the sorted sample
        local s = copy_sorted(a)
        local n = #s
        local d_max = 0
        for i = 1, n do
            local f_emp_lo = (i - 1) / n
            local f_emp_hi = i / n
            local f_th = b(s[i])
            local d1 = math.abs(f_emp_hi - f_th)
            local d2 = math.abs(f_th - f_emp_lo)
            if d1 > d_max then d_max = d1 end
            if d2 > d_max then d_max = d2 end
        end
        return { d = d_max, n = n, p_value = ks_pvalue(d_max, n) }
    end
    -- two-sample
    local sa = copy_sorted(a)
    local sb = copy_sorted(b)
    local na, nb = #sa, #sb
    local i, j = 1, 1
    local d_max = 0
    while i <= na and j <= nb do
        local va, vb = sa[i], sb[j]
        if va <= vb then i = i + 1 end
        if vb <= va then j = j + 1 end
        local fa = (i - 1) / na
        local fb = (j - 1) / nb
        local d = math.abs(fa - fb)
        if d > d_max then d_max = d end
    end
    local n_eff = (na * nb) / (na + nb)
    return { d = d_max, n_a = na, n_b = nb, p_value = ks_pvalue(d_max, n_eff) }
end

-- ===== Summary ==========================================================
--
-- M.summary() with no args returns a Welford streaming object. The :add(v)
-- method updates running mean and variance in O(1) per value without
-- accumulating the whole sample.
--
-- M.summary(t) keeps the original one-shot behaviour so callers can still
-- get a quick descriptive dashboard from an existing table.

local _summary_mt = {}
_summary_mt.__index = _summary_mt

function _summary_mt:add(v)
    self.n = self.n + 1
    if v < self.min_v then self.min_v = v end
    if v > self.max_v then self.max_v = v end
    -- Welford
    local delta = v - self.mean_v
    self.mean_v = self.mean_v + delta / self.n
    local delta2 = v - self.mean_v
    self.m2 = self.m2 + delta * delta2
end

function _summary_mt:add_all(t)
    for i = 1, #t do self:add(t[i]) end
    return self
end

function _summary_mt:mean()   return self.mean_v end
function _summary_mt:var()    if self.n < 2 then return 0 / 0 end; return self.m2 / (self.n - 1) end
function _summary_mt:stddev() return sqrt(self:var()) end
function _summary_mt:min()    return self.min_v end
function _summary_mt:max()    return self.max_v end
function _summary_mt:count()  return self.n end

function _summary_mt:result()
    return {
        n     = self.n,
        min   = self.n > 0 and self.min_v or 0 / 0,
        max   = self.n > 0 and self.max_v or 0 / 0,
        mean  = self.n > 0 and self.mean_v or 0 / 0,
        var   = self:var(),
        stddev = self:stddev(),
    }
end

function M.summary(t)
    if t == nil then
        return setmetatable({
            n      = 0,
            min_v  = math.huge,
            max_v  = -math.huge,
            mean_v = 0,
            m2     = 0,
        }, _summary_mt)
    end
    -- legacy one-shot snapshot from a table
    if #t == 0 then return { n = 0 } end
    local q1, q2, q3 = M.quartiles(t)
    return {
        n      = #t,
        min    = M.min(t),
        max    = M.max(t),
        mean   = M.mean(t),
        median = q2,
        stdev  = M.stdev(t),
        q1     = q1,
        q3     = q3,
    }
end

return M
