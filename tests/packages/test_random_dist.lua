-- tests/packages/test_random_dist.lua : distribution PDF/CDF/quantile checks
-- against known-correct closed-form reference values, plus seeded determinism.
-- Pure-Lua package (xoshiro256** RNG + analytic stats) -- no native DLL needed.
local ok_req, random_dist = pcall(require, "random_dist")
if not ok_req then print("[~] SKIP test_random_dist") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_random_dist: " .. tostring(m)) end end
local function approx(a, b, tol) return math.abs(a - b) <= (tol or 1e-9) end

-- ===== Normal(0,1) =====
local n = random_dist.normal(0, 1)
ok(approx(n:cdf(0), 0.5, 1e-9), "normal_cdf(0)=0.5")
-- erf approx (Abramowitz & Stegun) has |err|<1.5e-7; loosen tolerance on tails
ok(approx(n:cdf(1.96), 0.975, 1e-3), "normal_cdf(1.96)~=0.975")
ok(approx(n:cdf(-1.96), 0.025, 1e-3), "normal_cdf(-1.96)~=0.025")
ok(approx(n:cdf(1.0) + n:cdf(-1.0), 1.0, 1e-6), "normal cdf symmetry")
ok(approx(n:pdf(0), 1 / math.sqrt(2 * math.pi), 1e-12), "normal_pdf(0)=1/sqrt(2pi)")
ok(approx(n:quantile(0.5), 0, 1e-6), "normal_quantile(0.5)=0")
ok(approx(n:cdf(n:quantile(0.84)), 0.84, 1e-3), "normal quantile/cdf round trip")
ok(n:mean() == 0, "normal mean=mu")
ok(n:variance() == 1, "normal var=sigma^2")
local n2 = random_dist.normal(5, 2)
ok(n2:mean() == 5, "normal(5,2) mean=5")
ok(n2:variance() == 4, "normal(5,2) var=4")
ok(approx(n2:cdf(5), 0.5, 1e-9), "normal(5,2) cdf at mean=0.5")

-- ===== Uniform =====
local u = random_dist.uniform(0, 1)
ok(approx(u:cdf(0.3), 0.3), "uniform(0,1) cdf(0.3)=0.3")
ok(u:cdf(-1) == 0, "uniform cdf below=0")
ok(u:cdf(2) == 1, "uniform cdf above=1")
ok(approx(u:pdf(0.5), 1.0), "uniform pdf=1")
ok(u:pdf(-1) == 0, "uniform pdf outside=0")
ok(approx(u:quantile(0.25), 0.25), "uniform quantile(0.25)=0.25")
ok(approx(u:mean(), 0.5), "uniform mean=0.5")
ok(approx(u:variance(), 1 / 12), "uniform var=1/12")
local u2 = random_dist.uniform(2, 6)
ok(approx(u2:cdf(4), 0.5), "uniform(2,6) cdf(4)=0.5")
ok(approx(u2:pdf(4), 0.25), "uniform(2,6) pdf=0.25")

-- ===== Exponential(2) =====
local e = random_dist.exponential(2)
ok(approx(e:cdf(0), 0), "exp cdf(0)=0")
ok(approx(e:cdf(1), 1 - math.exp(-2)), "exp(2) cdf(1)=1-e^-2")
ok(approx(e:pdf(1), 2 * math.exp(-2)), "exp(2) pdf(1)=2e^-2")
ok(approx(e:mean(), 0.5), "exp(2) mean=1/lambda")
ok(approx(e:variance(), 0.25), "exp(2) var=1/lambda^2")
ok(approx(e:cdf(e:quantile(0.7)), 0.7, 1e-9), "exp quantile/cdf round trip")
ok(approx(e:quantile(0.5), math.log(2) / 2, 1e-9), "exp median=ln2/lambda")

-- ===== Binomial(10, 0.5) =====
local b = random_dist.binomial(10, 0.5)
ok(b:mean() == 5, "binomial(10,0.5) mean=np=5")
ok(b:variance() == 2.5, "binomial(10,0.5) var=np(1-p)=2.5")
-- pmf(5) = C(10,5)/2^10 = 252/1024
ok(approx(b:pdf(5), 252 / 1024, 1e-9), "binomial pmf(5)=252/1024")
ok(approx(b:pdf(0), 1 / 1024, 1e-9), "binomial pmf(0)=1/1024")
ok(approx(b:pdf(10), 1 / 1024, 1e-9), "binomial pmf(10)=1/1024")
-- CDF(5) = (1+10+45+120+210+252)/1024 = 638/1024 (cross-checks reg_beta path)
ok(approx(b:cdf(5), 638 / 1024, 1e-6), "binomial cdf(5)=638/1024")
ok(b:cdf(10) == 1, "binomial cdf(n)=1")
ok(b:pdf(-1) == 0, "binomial pmf(-1)=0")
ok(b:pdf(11) == 0, "binomial pmf(11)=0")

-- ===== Poisson(3) =====
local po = random_dist.poisson(3)
ok(po:mean() == 3, "poisson mean=lambda=3")
ok(po:variance() == 3, "poisson var=lambda=3")
ok(approx(po:pdf(0), math.exp(-3), 1e-12), "poisson pmf(0)=e^-3")
ok(approx(po:pdf(2), math.exp(-3) * 9 / 2, 1e-12), "poisson pmf(2)=4.5 e^-3")
ok(approx(po:cdf(0), math.exp(-3), 1e-9), "poisson cdf(0)=e^-3")

-- ===== Bernoulli(0.3) =====
local be = random_dist.bernoulli(0.3)
ok(approx(be:pdf(0), 0.7), "bernoulli pmf(0)=1-p")
ok(approx(be:pdf(1), 0.3), "bernoulli pmf(1)=p")
ok(be:pdf(2) == 0, "bernoulli pmf(2)=0")
ok(approx(be:mean(), 0.3), "bernoulli mean=p")
ok(approx(be:variance(), 0.21), "bernoulli var=p(1-p)")

-- ===== Geometric(0.25) =====
local g = random_dist.geometric(0.25)
ok(approx(g:pdf(1), 0.25), "geometric pmf(1)=p")
ok(approx(g:pdf(2), 0.25 * 0.75), "geometric pmf(2)=p(1-p)")
ok(approx(g:mean(), 4), "geometric mean=1/p")
ok(approx(g:cdf(2), 1 - 0.75 ^ 2), "geometric cdf(2)")

-- ===== Lognormal(0,1) =====
local ln = random_dist.lognormal(0, 1)
ok(approx(ln:cdf(1), 0.5, 1e-9), "lognormal cdf(median=1)=0.5")
ok(ln:cdf(0) == 0, "lognormal cdf(0)=0")
ok(ln:pdf(-1) == 0, "lognormal pdf neg=0")

-- ===== Weibull(1,1) == Exponential(1) =====
local w = random_dist.weibull(1, 1)
ok(approx(w:cdf(1), 1 - math.exp(-1), 1e-9), "weibull(1,1) cdf(1)=1-e^-1")
ok(approx(w:quantile(0.5), math.log(2), 1e-9), "weibull(1,1) median=ln2")

-- ===== Pareto(3,1) =====
local pa = random_dist.pareto(3, 1)
ok(pa:cdf(0.5) == 0, "pareto cdf below xm=0")
ok(approx(pa:cdf(2), 1 - (1 / 2) ^ 3, 1e-9), "pareto cdf(2)=1-(xm/x)^alpha")
ok(approx(pa:mean(), 3 / 2), "pareto mean=alpha*xm/(alpha-1)")

-- ===== Cauchy(0,1) =====
local ca = random_dist.cauchy(0, 1)
ok(approx(ca:cdf(0), 0.5, 1e-12), "cauchy cdf(0)=0.5")
ok(approx(ca:pdf(0), 1 / math.pi, 1e-12), "cauchy pdf(0)=1/pi")
ok(approx(ca:quantile(0.5), 0, 1e-9), "cauchy quantile(0.5)=0")
ok(approx(ca:cdf(1), 0.75, 1e-9), "cauchy cdf(1)=0.75")

-- ===== Chi-squared(2) == Exponential rate 1/2 =====
local cs = random_dist.chi_squared(2)
ok(cs:mean() == 2, "chi2(2) mean=k")
ok(cs:variance() == 4, "chi2(2) var=2k")
ok(approx(cs:cdf(2), 1 - math.exp(-1), 1e-6), "chi2(2) cdf(2)=1-e^-1")

-- ===== module-level helpers =====
ok(approx(random_dist.normal_cdf_unit(0), 0.5, 1e-9), "normal_cdf_unit(0)=0.5")
ok(approx(random_dist.erf(0), 0, 1e-9), "erf(0)=0")
-- gamma_fn known values: Gamma(5)=4!=24, Gamma(1)=1, Gamma(1/2)=sqrt(pi)
ok(approx(random_dist.gamma_fn(5), 24, 1e-6), "gamma_fn(5)=24")
ok(approx(random_dist.gamma_fn(1), 1, 1e-9), "gamma_fn(1)=1")
ok(approx(random_dist.gamma_fn(0.5), math.sqrt(math.pi), 1e-6), "gamma_fn(0.5)=sqrt(pi)")

-- ===== seeded determinism =====
local r1 = random_dist.create_rng(12345)
local r2 = random_dist.create_rng(12345)
local same = true
for _ = 1, 20 do
  if r1:next_double() ~= r2:next_double() then same = false break end
end
ok(same, "create_rng same seed -> same sequence")
ok(random_dist.create_rng(12345):next_double() ~= random_dist.create_rng(99999):next_double(),
   "different seed -> different first draw")
local rd = random_dist.create_rng(7)
local inrange = true
for _ = 1, 50 do local v = rd:next_double(); if v < 0 or v >= 1 then inrange = false break end end
ok(inrange, "next_double in [0,1)")
local d1 = random_dist.normal(0, 1):bind(random_dist.create_rng(42))
local d2 = random_dist.normal(0, 1):bind(random_dist.create_rng(42))
ok(d1:sample() == d2:sample(), "bound rng -> deterministic sample")

if fails == 0 then print("[+] PASS test_random_dist") os.exit(0) else os.exit(1) end
